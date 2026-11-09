import Foundation
import Synchronization
import Testing
@testable import MinutesCore

/// 決められた順に失敗し、尽きたら成功する文字起こし。
private final class ScriptedTranscriber: BatchTranscriber, Sendable {
    let id: String
    let runsLocally: Bool
    private let failures: Mutex<[any Error]>
    /// 尽きたあとも毎回投げる失敗（nil なら成功）。
    private let always: (any Error)?
    let calls = Mutex(0)

    init(id: String, runsLocally: Bool, failures: [any Error] = [], always: (any Error)? = nil) {
        self.id = id
        self.runsLocally = runsLocally
        self.failures = Mutex(failures)
        self.always = always
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        calls.withLock { $0 += 1 }
        if let failure = failures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) { throw failure }
        if let always { throw always }
        return TranscriptionResult(segments: [.init(start: 0, end: 1, text: "合成会議の本文", speakerLabel: request.diarize ? "speaker_0" : nil)],
                                   providerMeta: ["provider": id])
    }
}

/// 止められるまで返らない送信（スリープで切れた接続の代わり）。
private final class HangingTranscriber: BatchTranscriber, Sendable {
    let id = "cloud.hanging"
    let runsLocally = false
    let cancelled = Mutex(false)
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        do { try await Task.sleep(for: .seconds(30)) } catch {
            cancelled.withLock { $0 = true }
            throw error
        }
        throw URLError(.timedOut)
    }
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// 1 回目は門が開くまで返らず、開いたら時間切れで失敗する（スリープで切れた送信）。2 回目からは成功する。
private final class GatedTranscriber: BatchTranscriber, Sendable {
    let id = "cloud.gated"
    let runsLocally = false
    let gate = Gate()
    let calls = Mutex(0)
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let count = calls.withLock { value -> Int in
            value += 1
            return value
        }
        if count == 1 {
            await gate.wait()
            throw URLError(.timedOut)
        }
        return TranscriptionResult(segments: [.init(start: 0, end: 1, text: "合成会議の本文", speakerLabel: request.diarize ? "speaker_0" : nil)],
                                   providerMeta: ["provider": id])
    }
}

private struct FailingSummarizer: Summarizing {
    var modelDescription: String { "fixture / prompt v0" }
    func summarize(_ input: SummaryInput) async throws -> MinutesSummary {
        throw PipelineError.summaryUnavailable
    }
}

/// テストで切り替える値（クロージャから読む）。
private final class Toggle: Sendable {
    private let state: Mutex<Bool>
    init(_ value: Bool) { state = Mutex(value) }
    var value: Bool { state.withLock { $0 } }
    func set(_ value: Bool) { state.withLock { $0 = value } }
}

private final class EventLog: Sendable {
    private let events = Mutex<[PostProcessingQueue.Event]>([])
    func append(_ event: PostProcessingQueue.Event) { events.withLock { $0.append(event) } }
    var hasDeferred: Bool { events.withLock { $0.contains { if case .deferred = $0 { true } else { false } } } }
    var hasFailed: Bool { events.withLock { $0.contains { if case .failed = $0 { true } else { false } } } }
}

private final class RetryFixture {
    let root: URL
    let store: Store
    /// true のあいだ、どの手順も 60 秒スリープしていたと測る。
    let asleep = Toggle(false)
    let networkAvailable = Toggle(true)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-retry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try Store.open(at: root.appendingPathComponent("test.sqlite"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// 合成の会議（system トラックだけ）。キューに依頼できるよう failed で作る。
    func meeting(status: MeetingStatus = .failed) throws -> MeetingRecord {
        let id = ULID.generate()
        let audio = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: Array(repeating: 0.1, count: 16_000), sampleRate: 16_000, to: audio.appendingPathComponent(RecordingSession.systemSTTName))
        return try store.createMeeting(.init(id: id, title: "合成会議", startedAt: Date(), endedAt: Date(), privacyMode: .cloudOk, status: status, audioDir: audio.path))
    }

    /// `asleep` が true のあいだ、どの手順も 60 秒スリープしていたと測る。
    func sleepMonitor(checkInterval: Duration) -> SleepMonitor {
        let asleep = self.asleep
        return SleepMonitor(start: { { asleep.value ? 60 : 0 } }, checkInterval: checkInterval, threshold: 10)
    }

    /// - Parameter checkInterval: 送信中にスリープを確かめる間隔（既定は 20 ms ですぐ気づく）。
    func pipeline(cloud: (any BatchTranscriber)?, local: any BatchTranscriber, summarizer: (any Summarizing)? = nil,
                  checkInterval: Duration = .milliseconds(20)) -> PostProcessPipeline {
        PostProcessPipeline(store: store, providers: PipelineProviders(cloud: cloud, local: local, summarizer: summarizer,
                                                                        exportDirectory: root.appendingPathComponent("export"),
                                                                        sleepMonitor: sleepMonitor(checkInterval: checkInterval)))
    }

    func queue(_ pipeline: PostProcessPipeline, events: EventLog? = nil,
               timing: PostProcessingQueue.RetryTiming = .init(afterSleep: .seconds(60), afterWake: .milliseconds(10), backoff: [.milliseconds(10)], offlineRecheck: .seconds(60))) -> PostProcessingQueue {
        let networkAvailable = self.networkAvailable
        return PostProcessingQueue(store: store, pipeline: pipeline, onEvent: { event in events?.append(event) },
                                   isNetworkAvailable: { networkAvailable.value }, timing: timing)
    }

    /// パイプラインを直接（キューを通さずに）待つ方針で走らせる。
    func runDeferred(_ pipeline: PostProcessPipeline, meeting: MeetingRecord) async throws -> PipelineOutcome {
        let lease = try store.acquireMeetingLease(meeting.id)
        return try await pipeline.run(meetingId: meeting.id, lease: lease, policy: .deferred)
    }

    func waitUntil(_ condition: () throws -> Bool) async throws {
        for _ in 0..<300 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("条件がそろわなかった")
    }
}

@Suite("スリープ・回線で止めた後処理の再開（SPEC §8.2）")
struct DeferredRetryTests {
    @Test("回線が切れて失敗したら、ローカルに切り替えずに待つ")
    func networkFailureWaits() async throws {
        let f = try RetryFixture(); defer { f.cleanup() }
        let meeting = try f.meeting(status: .finalizing)
        let cloud = ScriptedTranscriber(id: "cloud.fake", runsLocally: false, failures: [URLError(.networkConnectionLost)])
        let local = ScriptedTranscriber(id: "local.fake", runsLocally: true)
        do {
            _ = try await f.runDeferred(f.pipeline(cloud: cloud, local: local), meeting: meeting)
            Issue.record("待つはず")
        } catch let failure as DeferredFailure {
            #expect(failure.reason == .network)
            #expect(failure.step == .transcribeFinal)
        }
        #expect(local.calls.withLock { $0 } == 0)
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .finalizing)
        let run = try #require(try f.store.latestRun(meetingId: meeting.id, step: PipelineStep.transcribeFinal.rawValue))
        #expect(run.runStatus == .failed)
        #expect(run.error?.contains(DeferReason.network.waitingMessage) == true)
    }

    @Test("CLI（immediate）はこれまでどおり、その場でローカルに切り替える")
    func immediateFallsBack() async throws {
        let f = try RetryFixture(); defer { f.cleanup() }
        let meeting = try f.meeting(status: .finalizing)
        let cloud = ScriptedTranscriber(id: "cloud.fake", runsLocally: false, always: URLError(.networkConnectionLost))
        let local = ScriptedTranscriber(id: "local.fake", runsLocally: true)
        _ = try await f.pipeline(cloud: cloud, local: local).run(meetingId: meeting.id)
        #expect(local.calls.withLock { $0 } == 1)
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .done)
        #expect(try f.store.latestRun(meetingId: meeting.id, step: PipelineStep.transcribeFinal.rawValue)?.provider?.contains("fallback") == true)
    }

    @Test("キーの誤りなど一時的でない失敗は、待たずにローカルに切り替える")
    func permanentFailureFallsBack() async throws {
        let f = try RetryFixture(); defer { f.cleanup() }
        let meeting = try f.meeting(status: .finalizing)
        let cloud = ScriptedTranscriber(id: "cloud.fake", runsLocally: false, always: TranscriptionError.httpError(provider: "cloud.fake", status: 401, body: "invalid key", requestID: nil))
        let local = ScriptedTranscriber(id: "local.fake", runsLocally: true)
        _ = try await f.runDeferred(f.pipeline(cloud: cloud, local: local), meeting: meeting)
        #expect(local.calls.withLock { $0 } == 1)
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .done)
    }

    @Test("クラウドもローカルも失敗したら、両方の理由を残す")
    func bothFailuresRecorded() async throws {
        let f = try RetryFixture(); defer { f.cleanup() }
        let meeting = try f.meeting(status: .finalizing)
        let cloud = ScriptedTranscriber(id: "cloud.fake", runsLocally: false, always: TranscriptionError.httpError(provider: "cloud.fake", status: 401, body: "invalid key", requestID: nil))
        let local = ScriptedTranscriber(id: "local.fake", runsLocally: true, always: TranscriptionError.diarizationFailed("合成の Core ML エラー"))
        do {
            _ = try await f.runDeferred(f.pipeline(cloud: cloud, local: local), meeting: meeting)
            Issue.record("失敗するはず")
        } catch {
            #expect(error.localizedDescription.contains("話者分離に失敗しました"))
            #expect(error.localizedDescription.contains("HTTP 401"))
        }
        let run = try #require(try f.store.latestRun(meetingId: meeting.id, step: PipelineStep.transcribeFinal.rawValue))
        #expect(run.error?.contains("合成の Core ML エラー") == true)
        #expect(run.error?.contains("cloud.fake") == true)
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .failed)
    }

    @Test("送信中にスリープを挟んだら、送信を止めて待つ（ローカルに切り替えない）")
    func sleepDuringUploadCancelsAndWaits() async throws {
        let f = try RetryFixture(); defer { f.cleanup() }
        let meeting = try f.meeting(status: .finalizing)
        f.asleep.set(true)
        let cloud = HangingTranscriber()
        let local = ScriptedTranscriber(id: "local.fake", runsLocally: true)
        do {
            _ = try await f.runDeferred(f.pipeline(cloud: cloud, local: local), meeting: meeting)
            Issue.record("待つはず")
        } catch let failure as DeferredFailure {
            #expect(failure.reason == .sleep)
        }
        #expect(cloud.cancelled.withLock { $0 })
        #expect(local.calls.withLock { $0 } == 0)
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .finalizing)
    }

    @Test("手順の途中でスリープしたら、要約の失敗も失敗にせず待つ。スリープがなければこれまでどおり警告", arguments: [true, false])
    func sleepDuringOptionalStep(asleep: Bool) async throws {
        let f = try RetryFixture(); defer { f.cleanup() }
        let meeting = try f.meeting(status: .finalizing)
        f.asleep.set(asleep)
        let pipeline = f.pipeline(cloud: nil, local: ScriptedTranscriber(id: "local.fake", runsLocally: true), summarizer: FailingSummarizer())
        if asleep {
            do {
                _ = try await f.runDeferred(pipeline, meeting: meeting)
                Issue.record("待つはず")
            } catch let failure as DeferredFailure {
                #expect(failure.reason == .sleep)
                #expect(failure.step == .summarize)
            }
            #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .finalizing)
        } else {
            let outcome = try await f.runDeferred(pipeline, meeting: meeting)
            #expect(outcome.warnings[.summarize] != nil)
            #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .done)
        }
    }

    @Test("待つ失敗の見分け: 回線・混雑・スリープ。キーの誤りや形式は待たない")
    func classification() {
        #expect(TransientFailure.reason(for: URLError(.timedOut)) == .network)
        #expect(TransientFailure.reason(for: URLError(.notConnectedToInternet)) == .network)
        #expect(TransientFailure.reason(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)) == .network)
        #expect(TransientFailure.reason(for: TranscriptionError.httpError(provider: "p", status: 503, body: "", requestID: nil)) == .server)
        #expect(TransientFailure.reason(for: TranscriptionError.httpError(provider: "p", status: 429, body: "", requestID: nil)) == .server)
        #expect(TransientFailure.reason(for: TranscriptionError.httpError(provider: "p", status: 401, body: "", requestID: nil)) == nil)
        #expect(TransientFailure.reason(for: TranscriptionError.unsupportedAudio("x")) == nil)
        #expect(TransientFailure.reason(for: URLError(.badURL)) == nil)
        #expect(TransientFailure.reason(for: SleepInterruption()) == .sleep)
    }

    @Test("スリープしていなければ、測った時間はほぼ 0")
    func sleepWatchWithoutSleep() async throws {
        let watch = SleepWatch()
        try await Task.sleep(for: .milliseconds(20))
        #expect(watch.sleptSeconds < 1)
    }

    @Test("キュー: 回線を待った依頼は失敗にせず、つながったら続きから再開して仕上げる")
    func queueResumesWhenNetworkReturns() async throws {
        let f = try RetryFixture(); defer { f.cleanup() }
        let meeting = try f.meeting()
        try f.store.requestPostProcessing(meetingId: meeting.id)
        f.networkAvailable.set(false)
        let cloud = ScriptedTranscriber(id: "cloud.fake", runsLocally: false, failures: [URLError(.notConnectedToInternet)])
        let local = ScriptedTranscriber(id: "local.fake", runsLocally: true)
        let events = EventLog()
        let queue = f.queue(f.pipeline(cloud: cloud, local: local), events: events)
        await queue.start()
        await queue.waitUntilIdle()

        let job = try #require(try f.store.postProcessingJobs().first)
        #expect(job.jobStatus == .queued)
        #expect(job.error == DeferReason.network.waitingMessage)
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .finalizing)
        #expect(await queue.waitingReason(meetingId: meeting.id) == .network)
        #expect(events.hasDeferred)
        #expect(!events.hasFailed)

        f.networkAvailable.set(true)
        await queue.networkBecameAvailable()
        try await f.waitUntil { try f.store.meeting(id: meeting.id)?.meetingStatus == .done }
        #expect(cloud.calls.withLock { $0 } == 2)
        #expect(local.calls.withLock { $0 } == 0)
        #expect(try f.store.postProcessingJobs().isEmpty)
    }

    @Test("キュー: 回線がつながっているのに失敗が続いたら、上限のあとはローカルに切り替える")
    func queueFallsBackAfterLimit() async throws {
        let f = try RetryFixture(); defer { f.cleanup() }
        let meeting = try f.meeting()
        try f.store.requestPostProcessing(meetingId: meeting.id)
        let cloud = ScriptedTranscriber(id: "cloud.fake", runsLocally: false, always: URLError(.networkConnectionLost))
        let local = ScriptedTranscriber(id: "local.fake", runsLocally: true)
        let queue = f.queue(f.pipeline(cloud: cloud, local: local))
        await queue.start()
        try await f.waitUntil { try f.store.meeting(id: meeting.id)?.meetingStatus == .done }
        #expect(cloud.calls.withLock { $0 } == PostProcessingQueue.transientFailureLimit + 1)
        #expect(local.calls.withLock { $0 } == 1)
    }

    @Test("キュー: スリープで止めた依頼は、そのあとに届いた起きた知らせで再開する")
    func queueResumesAfterWake() async throws {
        let f = try RetryFixture(); defer { f.cleanup() }
        let meeting = try f.meeting()
        try f.store.requestPostProcessing(meetingId: meeting.id)
        f.asleep.set(true)
        let cloud = ScriptedTranscriber(id: "cloud.fake", runsLocally: false, failures: [URLError(.timedOut)])
        let local = ScriptedTranscriber(id: "local.fake", runsLocally: true)
        let queue = f.queue(f.pipeline(cloud: cloud, local: local))
        await queue.start()
        await queue.waitUntilIdle()
        #expect(await queue.waitingReason(meetingId: meeting.id) == .sleep)
        #expect(try f.store.postProcessingJobs().first?.error == DeferReason.sleep.waitingMessage)
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .finalizing)

        f.asleep.set(false)
        await queue.systemDidWake()
        try await f.waitUntil { try f.store.meeting(id: meeting.id)?.meetingStatus == .done }
        #expect(cloud.calls.withLock { $0 } == 2)
        #expect(local.calls.withLock { $0 } == 0)
    }

    @Test("キュー: 蓋を開けた知らせが送信の中断より先に届いても、待たずに再開する")
    func queueResumesWhenWakeArrivesFirst() async throws {
        let f = try RetryFixture(); defer { f.cleanup() }
        let meeting = try f.meeting()
        try f.store.requestPostProcessing(meetingId: meeting.id)
        f.asleep.set(true)
        let cloud = GatedTranscriber()
        let local = ScriptedTranscriber(id: "local.fake", runsLocally: true)
        // 見張りの間隔を長くし、送信の失敗（門を開けたときの時間切れ）で止まるようにする
        let queue = f.queue(f.pipeline(cloud: cloud, local: local, checkInterval: .seconds(30)))
        await queue.start()
        try await f.waitUntil { cloud.calls.withLock { $0 } == 1 }
        // 実際の順番: 蓋を開けると起きた知らせが届き、そのあとで送信が失敗する
        await queue.systemDidWake()
        await cloud.gate.open()
        // 待ちの既定（afterSleep、60 秒）ではなく、afterWake（10 ms）で再開する
        try await f.waitUntil { try f.store.meeting(id: meeting.id)?.meetingStatus == .done }
        #expect(cloud.calls.withLock { $0 } == 2)
        #expect(local.calls.withLock { $0 } == 0)
    }

    @Test("キュー: 待っている依頼は「今すぐやり直す」で待たずに試せる")
    func queueRetryNow() async throws {
        let f = try RetryFixture(); defer { f.cleanup() }
        let meeting = try f.meeting()
        try f.store.requestPostProcessing(meetingId: meeting.id)
        // 回線の知らせは切れたまま（誤り）でも、実際にはつながっている
        f.networkAvailable.set(false)
        let cloud = ScriptedTranscriber(id: "cloud.fake", runsLocally: false, failures: [URLError(.notConnectedToInternet)])
        let queue = f.queue(f.pipeline(cloud: cloud, local: ScriptedTranscriber(id: "local.fake", runsLocally: true)))
        await queue.start()
        await queue.waitUntilIdle()
        #expect(await queue.waitingReason(meetingId: meeting.id) == .network)
        await queue.retryNow(meetingId: meeting.id)
        try await f.waitUntil { try f.store.meeting(id: meeting.id)?.meetingStatus == .done }
        #expect(cloud.calls.withLock { $0 } == 2)
    }
}
