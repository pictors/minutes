import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import MinutesCore

private final class FailingAudioWriter: TrackFileWriting {
    private var writes = 0
    private let failAt: Int
    init(failAt: Int) { self.failAt = failAt }
    func write(from buffer: AVAudioPCMBuffer) throws {
        writes += 1
        if writes >= failAt { throw CocoaError(.fileWriteOutOfSpace) }
    }
    func close() {}
}

private final class FakeRecording: MeetingRecording, @unchecked Sendable {
    let options: RecordingOptions
    let startedAt: Date? = Date()
    let tappedProcesses: [AudioProcessInfo] = []
    let systemChunks: AsyncStream<AudioChunk>? = nil
    let micChunks: AsyncStream<AudioChunk>? = nil
    var onEvent: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (CaptureFailure) -> Void)?
    let stopped = Mutex(0)
    let started = Mutex(0)
    var stopFailure = false
    var startFailure = false
    var failureOnStart: CaptureFailure?
    let startGate: AsyncGate?
    init(options: RecordingOptions, startGate: AsyncGate? = nil) { self.options = options; self.startGate = startGate }
    func start() async throws {
        started.withLock { $0 += 1 }
        await startGate?.wait()
        if let failureOnStart { onFailure?(failureOnStart) }
        if startFailure { throw CocoaError(.fileWriteNoPermission) }
    }
    func finishRecording() throws {
        stopped.withLock { $0 += 1 }
        if stopFailure { throw CocoaError(.fileWriteOutOfSpace) }
    }
    func snapshot() -> RecordingSession.Snapshot {
        .init(elapsedSeconds: 1, system: nil, mic: nil, cpuPercent: 0, residentBytes: 0, tappedProcessCount: 0)
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() { opened = true; for continuation in continuations { continuation.resume() }; continuations = [] }
}

@Suite("録音失敗の伝播")
struct CaptureFailureTests {
    @Test("ファイル作成失敗を一度だけ通知して成功時間を進めない")
    func openingFailure() {
        let failures = Mutex<[CaptureFailure]>([])
        let pipeline = TrackPipeline(name: "system", timelineStartHostTime: HostClock.now(), archiveURL: nil, sttURL: URL(fileURLWithPath: "/unused.wav"), onFailure: { failure in failures.withLock { $0.append(failure) } }, writerFactory: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        for i in 0..<3 { pipeline.enqueue(PCMChunk(channels: [Array(repeating: 0.2, count: 1600)], sampleRate: 16_000, hostTime: 0, sampleTime: Double(i * 1600))) }
        let stats = pipeline.finish()
        #expect(stats.failure?.operation == "WAV ファイル作成")
        #expect(stats.writtenSeconds == 0)
        #expect((stats.sttWrittenFrames ?? 0) == 0)
        #expect(failures.withLock { $0.count } == 1)
    }

    @Test("AAC/WAV 書き込み失敗以後は成功フレームを増やさない", arguments: ["archive", "stt"])
    func writingFailure(track: String) {
        let failures = Mutex<[CaptureFailure]>([])
        let pipeline = TrackPipeline(name: "system", timelineStartHostTime: HostClock.now(), archiveURL: URL(fileURLWithPath: "/archive.m4a"), sttURL: URL(fileURLWithPath: "/stt.wav"), onFailure: { failure in failures.withLock { $0.append(failure) } }, writerFactory: { url, _ in
            FailingAudioWriter(failAt: url.deletingPathExtension().lastPathComponent == track ? 2 : Int.max)
        })
        for i in 0..<5 { pipeline.enqueue(PCMChunk(channels: [Array(repeating: 0.2, count: 1600)], sampleRate: 16_000, hostTime: 0, sampleTime: Double(i * 1600))) }
        let stats = pipeline.finish()
        #expect(stats.failure != nil)
        #expect(abs(stats.writtenSeconds - 0.1) < 0.001)
        #expect(failures.withLock { $0.count } == 1)
        #expect((track == "archive" ? stats.archiveWrittenFrames : stats.sttWrittenFrames) == 1600)
        #expect(pipeline.finish() == stats)
    }

    @Test("capture error / stop error は failed として保存し後処理を開始しない", arguments: [false, true])
    func controllerFailure(atStop: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-capture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: FakeTranscriber(id: "local", runsLocally: true, segments: []), summarizer: nil, exportDirectory: root))
        let capture = FakeRecording(options: RecordingOptions(outputDirectory: root))
        capture.stopFailure = atStop
        var config = SessionConfiguration(targetBundleIdentifiers: [], audioRootDirectory: root)
        config.liveTranscription = false
        let controller = MeetingSessionController(store: store, pipeline: pipeline, configuration: config, makeRecording: { _ in capture })
        try await controller.start(PendingMeetingInfo(title: "disk failure"))
        let id = try #require(await controller.currentMeeting?.id)
        if atStop { await controller.stop() }
        else {
            capture.onFailure?(CaptureFailure(track: "mic", operation: "WAV 書き込み", message: "disk full"))
            for _ in 0..<100 {
                if await controller.state == .idle { break }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(await controller.state == .idle)
        #expect(await controller.lastError != nil)
        #expect(capture.stopped.withLock { $0 } == 1)
        #expect(try store.meeting(id: id)?.meetingStatus == .failed)
        #expect(try store.latestRun(meetingId: id, step: "capture")?.runStatus == .failed)
        #expect(try store.latestRun(meetingId: id, step: "transcribe_final") == nil)
        let lease = try store.acquireMeetingLease(id)
        withExtendedLifetime(lease) {}
    }

    @Test("字幕処理がキャンセルを無視しても停止の待ち時間を超えない")
    func drainTimeout() async {
        let gate = AsyncGate()
        let finished = Mutex(false)
        let task = Task { await gate.wait(); finished.withLock { $0 = true } }
        await TaskDrain.wait([task], timeout: .milliseconds(20))
        #expect(!finished.withLock { $0 })
        #expect(task.isCancelled)
        await gate.open()
        await task.value
    }

    @Test("権限待ちなど start の await 中でも二重起動を拒否")
    func concurrentStart() async throws {
        let store = try Store.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-start-" + UUID().uuidString)
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: FakeTranscriber(id: "local", runsLocally: true, segments: []), summarizer: nil, exportDirectory: root))
        let gate = AsyncGate()
        let capture = FakeRecording(options: RecordingOptions(outputDirectory: root), startGate: gate)
        var config = SessionConfiguration(targetBundleIdentifiers: [], audioRootDirectory: root)
        config.liveTranscription = false
        let controller = MeetingSessionController(store: store, pipeline: pipeline, configuration: config, makeRecording: { _ in capture })
        let first = Task { try await controller.arm(PendingMeetingInfo(title: "one")) }
        for _ in 0..<100 {
            if capture.started.withLock({ $0 }) > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await #expect(throws: AudioCaptureError.self) { try await controller.start(PendingMeetingInfo(title: "two")) }
        await gate.open()
        try await first.value
        #expect(capture.started.withLock { $0 } == 1)
        await controller.disarm()
        #expect(try store.listMeetings().isEmpty)
    }

    @Test("CLI 共通処理は待機開始前・待機中の録音失敗を取りこぼさず、一度だけ終了", arguments: [false, true])
    func cliCaptureFailure(beforeWait: Bool) async throws {
        let failure = CaptureFailure(track: "system", operation: "WAV 書き込み", message: "fixture disk full")
        let capture = FakeRecording(options: RecordingOptions(outputDirectory: URL(fileURLWithPath: "/unused")))
        if beforeWait { capture.failureOnStart = failure }
        let run = RecordingRun(recording: capture)
        try await run.start()
        let waiting = Task { await run.stopRequest.wait() }
        if !beforeWait { capture.onFailure?(failure) }
        // 不具合時もテスト自体は永久待機せず失敗する。
        let fallback = Task { try? await Task.sleep(for: .seconds(1)); run.stopRequest.request(.timeout) }
        let reason = await waiting.value
        fallback.cancel()
        #expect(reason == .failure(failure))
        #expect(throws: failure) { try run.finish(after: reason) }
        try run.close()
        #expect(capture.stopped.withLock { $0 } == 1)
        #expect(capture.onFailure == nil)
    }

    @Test("CLI 開始失敗でも録音を閉じ、終了失敗は成功扱いにしない")
    func cliStartAndFinishErrors() async throws {
        let capture = FakeRecording(options: RecordingOptions(outputDirectory: URL(fileURLWithPath: "/unused")))
        capture.startFailure = true
        let run = RecordingRun(recording: capture)
        await #expect(throws: CocoaError.self) { try await run.start() }
        try run.close()
        #expect(capture.stopped.withLock { $0 } == 1)

        let closeFailure = FakeRecording(options: capture.options)
        closeFailure.stopFailure = true
        let other = RecordingRun(recording: closeFailure)
        try await other.start()
        #expect(throws: CocoaError.self) { try other.finish(after: .signal) }
        try other.close()
        #expect(closeFailure.stopped.withLock { $0 } == 1)
    }

    @Test("CLI のキャンセルは待機を解除し、最初の停止理由を維持する")
    func cliCancellation() async throws {
        let capture = FakeRecording(options: RecordingOptions(outputDirectory: URL(fileURLWithPath: "/unused")))
        let run = RecordingRun(recording: capture)
        try await run.start()
        let waiting = Task { await run.stopRequest.wait() }
        waiting.cancel()
        let reason = await waiting.value
        #expect(reason == .cancelled)
        #expect(throws: CancellationError.self) { try run.finish(after: reason) }
        #expect(capture.stopped.withLock { $0 } == 1)
        run.stopRequest.request(.signal)
        #expect(await run.stopRequest.wait() == .cancelled)
    }

    @Test("入力停止監視は UI / CLI の snapshot 呼び出しなしで動き、一度だけ失敗を通知")
    func autonomousWatchdog() async throws {
        let failures = Mutex<[CaptureFailure]>([])
        let snapshots = Mutex(0)
        let track = TrackPipeline(name: "mic", timelineStartHostTime: HostClock.now(), archiveURL: nil, sttURL: nil, streamLiveAudio: false)
        let stats = track.finish()
        let watchdog = CaptureWatchdog(startTime: 100, tapAutoStart: false, interval: 0.01, now: { 106 }, snapshots: {
            snapshots.withLock { $0 += 1 }
            return [stats]
        }, onFailure: { failure in failures.withLock { $0.append(failure) } })
        defer { watchdog.stop() }
        for _ in 0..<100 {
            if failures.withLock({ !$0.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(failures.withLock { $0.first?.track } == "mic")
        #expect(failures.withLock { $0.first?.operation } == "音声入力の監視")
        try await Task.sleep(for: .milliseconds(40))
        #expect(snapshots.withLock { $0 } == 1)
        #expect(failures.withLock { $0.count } == 1)
    }

    @Test("入力待ちの自動開始と到着中の音声は watchdog で途切れとみなさない")
    func watchdogHealthyAndArmed() {
        let track = TrackPipeline(name: "system", timelineStartHostTime: HostClock.now(), archiveURL: nil, sttURL: nil, streamLiveAudio: false)
        var stats = track.finish()
        #expect(!CaptureWatchdog.isStalled(stats: stats, elapsed: 60, tapAutoStart: true))
        #expect(CaptureWatchdog.isStalled(stats: stats, elapsed: 6, tapAutoStart: false))
        stats.lastChunkTimelineEnd = 59
        #expect(!CaptureWatchdog.isStalled(stats: stats, elapsed: 60, tapAutoStart: false))
        #expect(CaptureWatchdog.isStalled(stats: stats, elapsed: 65, tapAutoStart: true))
    }

    @Test("停止済み watchdog は遅れて入力停止を通知しない")
    func stoppedWatchdog() async throws {
        let calls = Mutex(0)
        let watchdog = CaptureWatchdog(startTime: 0, tapAutoStart: false, interval: 0.05, now: { 100 }, snapshots: {
            calls.withLock { $0 += 1 }
            return []
        }, onFailure: { _ in Issue.record("停止後に失敗通知") })
        watchdog.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("ライブ音声の上限到達時は字幕を停止し、録音ファイルは全フレームを保存する")
    func boundedLiveBuffer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-live-buffer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.wav")
        let errors = Mutex<[String]>([])
        let track = TrackPipeline(name: "system", timelineStartHostTime: HostClock.now(), archiveURL: nil, sttURL: url, liveBufferLimit: 2, onLiveFailure: { message in errors.withLock { $0.append(message) } })
        // 消費者が止まっていても、録音は 1 秒分を保存し続ける。
        for index in 0..<10 {
            track.enqueue(PCMChunk(channels: [Array(repeating: 0.2, count: 1600)], sampleRate: 16_000, hostTime: 0, sampleTime: Double(index * 1600)))
        }
        let stats = track.finish()
        var chunks: [AudioChunk] = []
        for await chunk in track.chunks { chunks.append(chunk) }
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.samples.count <= 1600 })
        #expect(errors.withLock { $0.count } == 1)
        #expect(stats.liveStreamFailure != nil)
        #expect(stats.failure == nil)
        #expect(stats.sttWrittenFrames == 16_000)
        #expect(abs(try AudioFileTools.duration(of: url) - 1) < 0.001)
    }

    @Test("字幕を使わない録音は live 音声を蓄積せず、ファイルだけ保存する")
    func disabledLiveBuffer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-no-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.wav")
        let track = TrackPipeline(name: "system", timelineStartHostTime: HostClock.now(), archiveURL: nil, sttURL: url, streamLiveAudio: false, liveBufferLimit: 1)
        track.enqueue(PCMChunk(channels: [Array(repeating: 0.2, count: 16_000)], sampleRate: 16_000, hostTime: 0, sampleTime: 0))
        let stats = track.finish()
        var count = 0
        for await _ in track.chunks { count += 1 }
        #expect(count == 0)
        #expect(stats.liveStreamFailure == nil)
        #expect(stats.sttWrittenFrames == 16_000)
        #expect(abs(try AudioFileTools.duration(of: url) - 1) < 0.001)
    }
}
