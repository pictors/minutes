import Foundation
import GRDB
import Synchronization
import Testing
@testable import MinutesCore

private actor ProcessingGate {
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

private final class QueueTranscriber: BatchTranscriber, Sendable {
    let id: String
    let runsLocally = true
    let calls = Mutex<[String]>([])
    let gate: ProcessingGate?
    let failFirst: Bool
    init(id: String = "queue-fixture", gate: ProcessingGate? = nil, failFirst: Bool = false) {
        self.id = id; self.gate = gate; self.failFirst = failFirst
    }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let count = calls.withLock { values -> Int in
            values.append(request.audioURL.deletingLastPathComponent().lastPathComponent)
            return values.count
        }
        if count == 1 {
            await gate?.wait()
            if failFirst { throw PipelineError.artifactMissing("fixture failure") }
        }
        return TranscriptionResult(segments: [.init(start: 0, end: 1, text: "合成会議の本文", speakerLabel: "speaker_0")], providerMeta: ["provider": id])
    }
}

private final class SyntheticMeetingRecording: MeetingRecording, @unchecked Sendable {
    let options: RecordingOptions
    private(set) var startedAt: Date?
    let tappedProcesses: [AudioProcessInfo] = []
    let systemChunks: AsyncStream<AudioChunk>? = nil
    let micChunks: AsyncStream<AudioChunk>? = nil
    var onEvent: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (CaptureFailure) -> Void)?
    let stopCount = Mutex(0)
    init(options: RecordingOptions) { self.options = options }
    func start() async throws {
        startedAt = Date()
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: Array(repeating: 0.1, count: 16_000), sampleRate: 16_000, to: options.outputDirectory.appendingPathComponent(RecordingSession.systemSTTName))
    }
    func finishRecording() throws { stopCount.withLock { $0 += 1 } }
    func snapshot() -> RecordingSession.Snapshot {
        .init(elapsedSeconds: 1, system: nil, mic: nil, cpuPercent: 0, residentBytes: 0, tappedProcessCount: 0)
    }
}

private struct QueueFixture {
    let root: URL
    let store: Store
    var database: URL { root.appendingPathComponent("test.sqlite") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-queue-" + UUID().uuidString)
        store = try Store.open(at: root.appendingPathComponent("test.sqlite"))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func pipeline(store: Store? = nil, provider: QueueTranscriber) -> PostProcessPipeline {
        PostProcessPipeline(store: store ?? self.store, providers: PipelineProviders(cloud: nil, local: provider, summarizer: nil, exportDirectory: root.appendingPathComponent("export")))
    }
    func meeting(title: String = "合成会議", status: MeetingStatus = .failed) throws -> MeetingRecord {
        let id = ULID.generate()
        let audio = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: Array(repeating: 0.1, count: 16_000), sampleRate: 16_000, to: audio.appendingPathComponent(RecordingSession.systemSTTName))
        return try store.createMeeting(.init(id: id, title: title, startedAt: Date(), endedAt: Date(), privacyMode: .localOnly, status: status, audioDir: audio.path))
    }
    func controller(pipeline: PostProcessPipeline, queue: PostProcessingQueue, onRecording: @escaping @Sendable (SyntheticMeetingRecording) -> Void = { _ in }) -> MeetingSessionController {
        var configuration = SessionConfiguration(targetBundleIdentifiers: [], audioRootDirectory: root)
        configuration.liveTranscription = false
        configuration.includeMic = false
        return MeetingSessionController(store: store, pipeline: pipeline, configuration: configuration, postProcessingQueue: queue, makeRecording: { options in
            let recording = SyntheticMeetingRecording(options: options)
            onRecording(recording)
            return recording
        })
    }
}

private func waitForTranscriber(_ provider: QueueTranscriber) async throws {
    for _ in 0..<200 {
        if provider.calls.withLock({ !$0.isEmpty }) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("後処理が開始されなかった")
    throw PipelineError.artifactMissing("worker did not start")
}

@Suite("録音と永続後処理キューの分離")
struct PostProcessingQueueTests {
    @Test("前の会議の後処理中に次を録音でき、前の成功・失敗が録音状態を変えない", arguments: [false, true])
    func nextRecordingDuringProcessing(fail: Bool) async throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        let gate = ProcessingGate()
        let provider = QueueTranscriber(gate: gate, failFirst: fail)
        let pipeline = f.pipeline(provider: provider)
        let queue = PostProcessingQueue(store: f.store, pipeline: pipeline)
        let recordings = Mutex<[SyntheticMeetingRecording]>([])
        let controller = f.controller(pipeline: pipeline, queue: queue, onRecording: { recording in recordings.withLock { $0.append(recording) } })
        try await controller.start(.init(title: "A", privacyMode: .localOnly))
        let first = try #require(await controller.currentMeeting)
        let lateFailure = recordings.withLock { $0[0].onFailure }
        await controller.stop()
        #expect(await controller.state == .idle)
        #expect(await controller.currentMeeting == nil)
        await queue.start()
        try await waitForTranscriber(provider)
        #expect(try f.store.postProcessingJobs().first?.jobStatus == .running)
        #expect(try f.store.meeting(id: first.id)?.meetingStatus == .finalizing)

        try await controller.start(.init(title: "B", privacyMode: .localOnly))
        let second = try #require(await controller.currentMeeting)
        #expect(second.id != first.id)
        // 古い録音の遅延コールバックが次の会議を失敗させない。
        lateFailure?(.init(track: "system", operation: "late callback", message: "old recording"))
        await gate.open()
        await queue.waitUntilIdle()
        #expect(await controller.state == .recording)
        #expect(await controller.currentMeeting?.id == second.id)
        #expect(await controller.lastError == nil)
        #expect(recordings.withLock { $0[0].stopCount.withLock { $0 } } == 1)
        #expect(recordings.withLock { $0[1].stopCount.withLock { $0 } } == 0)
        #expect(try f.store.meeting(id: first.id)?.meetingStatus == (fail ? .failed : .done))
        #expect(try f.store.meeting(id: second.id)?.meetingStatus == .recording)
        await controller.stop()
        await queue.start()
        await queue.waitUntilIdle()
        #expect(try f.store.meeting(id: second.id)?.meetingStatus == .done)
    }

    @Test("二つのワーカーでも同じ DB の後処理は重複せず一件ずつ実行する")
    func serialAndDeduplicatedWorkers() async throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        let a = try f.meeting(title: "A")
        let b = try f.meeting(title: "B")
        try f.store.requestPostProcessing(meetingId: a.id)
        try f.store.requestPostProcessing(meetingId: a.id)
        try f.store.requestPostProcessing(meetingId: b.id)
        let gate = ProcessingGate()
        let provider = QueueTranscriber(gate: gate)
        let queue = PostProcessingQueue(store: f.store, pipeline: f.pipeline(provider: provider))
        let otherStore = try Store.open(at: f.database)
        let other = PostProcessingQueue(store: otherStore, pipeline: f.pipeline(store: otherStore, provider: provider))
        await queue.start()
        await other.start()
        try await waitForTranscriber(provider)
        #expect(provider.calls.withLock { $0.count } == 1)
        #expect(try f.store.postProcessingJobs().map(\.jobStatus) == [.running, .queued])
        #expect(throws: StoreError.self) { try f.store.deleteMeeting(id: b.id) }
        await gate.open()
        await queue.waitUntilIdle()
        await other.waitUntilIdle()
        #expect(provider.calls.withLock { $0 } == [a.id, b.id])
        #expect(try f.store.postProcessingJobs().isEmpty)
    }

    @Test("待機中と実行途中のジョブを再起動後に再開する", arguments: [false, true])
    func resumePersistedJobs(wasRunning: Bool) async throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        let meeting = try f.meeting()
        try f.store.requestPostProcessing(meetingId: meeting.id)
        if wasRunning {
            let lease = try f.store.acquireMeetingLease(meeting.id)
            #expect(try f.store.beginPostProcessing(meetingId: meeting.id, lease: lease))
            _ = try f.store.recordRun(meetingId: meeting.id, step: "transcribe_final", status: .running)
            withExtendedLifetime(lease) {}
        }
        let reopened = try Store.open(at: f.database)
        #expect(try reopened.postProcessingJobs().first?.jobStatus == .queued)
        #expect(try reopened.meeting(id: meeting.id)?.meetingStatus == .finalizing)
        if wasRunning { #expect(try reopened.latestRun(meetingId: meeting.id, step: "transcribe_final")?.runStatus == .failed) }
        let provider = QueueTranscriber()
        let queue = PostProcessingQueue(store: reopened, pipeline: f.pipeline(store: reopened, provider: provider))
        await queue.start()
        await queue.waitUntilIdle()
        #expect(try reopened.meeting(id: meeting.id)?.meetingStatus == .done)
        #expect(try reopened.postProcessingJobs().isEmpty)
        #expect(provider.calls.withLock { $0 } == [meeting.id])
    }

    @Test("別の Store を開いても実行中ワーカーの状態と所有権を維持する")
    func reopenWhileRunning() async throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        let meeting = try f.meeting()
        try f.store.requestPostProcessing(meetingId: meeting.id)
        let gate = ProcessingGate()
        let provider = QueueTranscriber(gate: gate)
        let queue = PostProcessingQueue(store: f.store, pipeline: f.pipeline(provider: provider))
        await queue.start()
        try await waitForTranscriber(provider)
        let reopened = try Store.open(at: f.database)
        #expect(try reopened.postProcessingJobs().first?.jobStatus == .running)
        #expect(try reopened.latestRun(meetingId: meeting.id, step: "transcribe_final")?.runStatus == .running)
        #expect(throws: StoreError.self) { try reopened.acquireMeetingLease(meeting.id) }
        await gate.open()
        await queue.waitUntilIdle()
    }

    @Test("完了直後の中断はジョブだけ清掃し、旧録音・失敗ジョブを勝手に再実行しない")
    func completedAndUnqueuedRecovery() async throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        let completed = try f.meeting()
        let interrupted = try f.meeting(status: .recording)
        let failed = try f.meeting()
        try f.store.requestPostProcessing(meetingId: completed.id)
        try f.store.requestPostProcessing(meetingId: failed.id)
        do {
            let lease = try f.store.acquireMeetingLease(completed.id)
            #expect(try f.store.beginPostProcessing(meetingId: completed.id, lease: lease))
            try f.store.setMeetingStatus(id: completed.id, status: .done)
            let failedLease = try f.store.acquireMeetingLease(failed.id)
            try f.store.finishPostProcessing(meetingId: failed.id, lease: failedLease, error: "再試行が必要")
        }
        let reopened = try Store.open(at: f.database)
        let provider = QueueTranscriber()
        let queue = PostProcessingQueue(store: reopened, pipeline: f.pipeline(store: reopened, provider: provider))
        await queue.start()
        await queue.waitUntilIdle()
        #expect(try reopened.meeting(id: completed.id)?.meetingStatus == .done)
        #expect(try reopened.meeting(id: interrupted.id)?.meetingStatus == .failed)
        #expect(try reopened.postProcessingJobs().map(\.meetingId) == [failed.id])
        #expect(provider.calls.withLock { $0.isEmpty })
    }

    @Test("一件の失敗で後続を止めず、失敗した会議だけ手動再試行できる")
    func failedJobDoesNotBlockFollowing() async throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        let a = try f.meeting(title: "A")
        let b = try f.meeting(title: "B")
        try f.store.requestPostProcessing(meetingId: a.id)
        try f.store.requestPostProcessing(meetingId: b.id)
        let provider = QueueTranscriber(failFirst: true)
        let queue = PostProcessingQueue(store: f.store, pipeline: f.pipeline(provider: provider))
        await queue.start()
        await queue.waitUntilIdle()
        #expect(try f.store.meeting(id: a.id)?.meetingStatus == .failed)
        #expect(try f.store.meeting(id: b.id)?.meetingStatus == .done)
        #expect(try f.store.postProcessingJobs().first?.jobStatus == .failed)
        let finalizedRun = try f.store.latestRun(meetingId: a.id, step: "finalize_audio")
        try f.store.requestPostProcessing(meetingId: a.id)
        await queue.start()
        await queue.waitUntilIdle()
        #expect(try f.store.postProcessingJobs().isEmpty)
        #expect(try f.store.meeting(id: a.id)?.meetingStatus == .done)
        #expect(try f.store.latestRun(meetingId: a.id, step: "finalize_audio")?.id == finalizedRun?.id)
        #expect(provider.calls.withLock { $0 } == [a.id, b.id, a.id])
    }

    @Test("設定変更は実行中の処理を差し替えず、次のジョブから適用する")
    func settingsApplyToNextJob() async throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        let a = try f.meeting(title: "A")
        let b = try f.meeting(title: "B")
        try f.store.requestPostProcessing(meetingId: a.id)
        try f.store.requestPostProcessing(meetingId: b.id)
        let gate = ProcessingGate()
        let original = QueueTranscriber(id: "original", gate: gate)
        let replacement = QueueTranscriber(id: "replacement")
        let queue = PostProcessingQueue(store: f.store, pipeline: f.pipeline(provider: original))
        await queue.start()
        try await waitForTranscriber(original)
        queue.updatePipeline(f.pipeline(provider: replacement))
        await gate.open()
        await queue.waitUntilIdle()
        #expect(original.calls.withLock { $0 } == [a.id])
        #expect(replacement.calls.withLock { $0 } == [b.id])
        #expect(try f.store.latestRun(meetingId: a.id, step: "transcribe_final")?.provider == "system: original")
        #expect(try f.store.latestRun(meetingId: b.id, step: "transcribe_final")?.provider == "system: replacement")
    }

    @Test("完了後のジョブ削除に失敗しても、再開時に STT を重複実行しない")
    func completionAcknowledgementFailure() async throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        let meeting = try f.meeting()
        try f.store.requestPostProcessing(meetingId: meeting.id)
        try await f.store.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_ack BEFORE DELETE ON post_processing_jobs BEGIN SELECT RAISE(ABORT, 'fixture ack failure'); END")
        }
        let provider = QueueTranscriber()
        let errors = Mutex<[String]>([])
        let queue = PostProcessingQueue(store: f.store, pipeline: f.pipeline(provider: provider)) { event in
            if case let .unavailable(message) = event { errors.withLock { $0.append(message) } }
        }
        await queue.start()
        await queue.waitUntilIdle()
        #expect(errors.withLock { $0.count } == 1)
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .done)
        #expect(try f.store.postProcessingJobs().first?.jobStatus == .running)
        try await f.store.writer.write { db in try db.execute(sql: "DROP TRIGGER refuse_ack") }
        await queue.start()
        await queue.waitUntilIdle()
        #expect(try f.store.postProcessingJobs().isEmpty)
        #expect(provider.calls.withLock { $0 } == [meeting.id])
    }

    @Test("CLI 相当の直接再処理に成功したら、キューの失敗表示と再実行依頼を清掃する")
    func directPipelineClearsFailedJob() async throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        let meeting = try f.meeting()
        try f.store.requestPostProcessing(meetingId: meeting.id)
        let provider = QueueTranscriber(failFirst: true)
        let pipeline = f.pipeline(provider: provider)
        let queue = PostProcessingQueue(store: f.store, pipeline: pipeline)
        await queue.start()
        await queue.waitUntilIdle()
        #expect(try f.store.postProcessingJobs().first?.jobStatus == .failed)
        try await pipeline.run(meetingId: meeting.id)
        #expect(try f.store.postProcessingJobs().isEmpty)
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .done)
        await queue.start()
        await queue.waitUntilIdle()
        #expect(provider.calls.withLock { $0.count } == 2)
    }

    @Test("別会議の録音中でも失敗済みの会議を再試行できる")
    func retryDuringRecording() async throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        let failed = try f.meeting()
        let provider = QueueTranscriber()
        let pipeline = f.pipeline(provider: provider)
        let queue = PostProcessingQueue(store: f.store, pipeline: pipeline)
        let controller = f.controller(pipeline: pipeline, queue: queue)
        try await controller.start(.init(title: "新しい会議", privacyMode: .localOnly))
        let activeId = try #require(await controller.currentMeeting?.id)
        try await controller.retryPipeline(meetingId: failed.id)
        await queue.waitUntilIdle()
        #expect(try f.store.meeting(id: failed.id)?.meetingStatus == .done)
        #expect(await controller.currentMeeting?.id == activeId)
        #expect(await controller.state == .recording)
        await controller.stop()
        await queue.start()
        await queue.waitUntilIdle()
    }

    @Test("後処理依頼の DB 保存が失敗しても音声を維持し、次の録音を妨げない")
    func enqueueFailurePreservesAudio() async throws {
        let f = try QueueFixture(); defer { f.cleanup() }
        try await f.store.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_job BEFORE INSERT ON post_processing_jobs BEGIN SELECT RAISE(ABORT, 'fixture job failure'); END")
        }
        let provider = QueueTranscriber()
        let pipeline = f.pipeline(provider: provider)
        let queue = PostProcessingQueue(store: f.store, pipeline: pipeline)
        let controller = f.controller(pipeline: pipeline, queue: queue)
        try await controller.start(.init(title: "保存失敗", privacyMode: .localOnly))
        let meeting = try #require(await controller.currentMeeting)
        await controller.stop()
        #expect(await controller.state == .idle)
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .failed)
        #expect(try f.store.postProcessingJobs().isEmpty)
        #expect(FileManager.default.fileExists(atPath: try #require(meeting.audioDir)))
        #expect(provider.calls.withLock { $0.isEmpty })
        try await controller.arm(.init(title: "次の会議", privacyMode: .localOnly))
        await controller.disarm()
    }

    @Test("recordingFinished は録音終了待ちから待機へ戻す")
    func recordingStateTransition() throws {
        var state = SessionStateMachine(state: .recording)
        #expect(throws: SessionTransitionError.self) { try state.handle(.recordingFinished) }
        try state.handle(.manualStop)
        try state.handle(.recordingFinished)
        #expect(state.state == .idle)
        try state.handle(.manualStart)
        #expect(state.state == .recording)
    }
}
