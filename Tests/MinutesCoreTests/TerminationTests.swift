import CoreServices
import Foundation
import Synchronization
import Testing
@testable import MinutesCore

/// 録音の代役。`start()` で録音の原点を決め、1 秒の WAV を書く。`active` で相手側の音声を検知した状態にする。
private final class TerminationFakeRecording: MeetingRecording, @unchecked Sendable {
    let options: RecordingOptions
    private(set) var startedAt: Date?
    let tappedProcesses: [AudioProcessInfo] = []
    let systemChunks: AsyncStream<AudioChunk>? = nil
    let micChunks: AsyncStream<AudioChunk>? = nil
    var onEvent: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (CaptureFailure) -> Void)?
    let active = Mutex(false)
    let stopped = Mutex(0)
    /// 録音の原点を、行を作った時刻からこの秒数だけずらす（許可の確認などで録音の開始が遅れた状態）。
    let originOffset: TimeInterval

    init(options: RecordingOptions, originOffset: TimeInterval = 0) {
        self.options = options
        self.originOffset = originOffset
    }

    func start() async throws {
        startedAt = Date().addingTimeInterval(originOffset)
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: Array(repeating: 0.1, count: 16_000), sampleRate: 16_000, to: options.outputDirectory.appendingPathComponent(RecordingSession.systemSTTName))
    }

    func finishRecording() throws { stopped.withLock { $0 += 1 } }

    func snapshot() -> RecordingSession.Snapshot {
        let level: Float = active.withLock { $0 } ? -20 : -120
        let stats = TrackStatsSnapshot(name: "system", sourceSampleRate: 48_000, sourceChannels: 2, archiveSampleRate: 48_000, receivedFrames: 0, receivedSeconds: 0, writtenSeconds: 0, firstChunkOffsetSeconds: nil, gapCount: 0, gapSeconds: 0, overlapCount: 0, overlapSeconds: 0, formatChanges: 0, lastRmsDb: level, intervalPeakRmsDb: level, activeSeconds: 0, lastChunkTimelineEnd: nil)
        return .init(elapsedSeconds: 1, system: stats, mic: nil, cpuPercent: 0, residentBytes: 0, tappedProcessCount: 0)
    }
}

private final class RecordingList: Sendable {
    let items = Mutex<[TerminationFakeRecording]>([])
}

private struct TerminationFixture {
    let root: URL
    let store: Store
    let recordings = RecordingList()
    let controller: MeetingSessionController

    init(originOffset: TimeInterval = 0) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-termination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try Store.inMemory()
        var configuration = SessionConfiguration(targetBundleIdentifiers: [], audioRootDirectory: root)
        configuration.liveTranscription = false
        configuration.includeMic = false
        configuration.monitorInterval = 0.05
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: FakeTranscriber(id: "local", runsLocally: true, segments: [.init(start: 0, end: 1, text: "本文")]), summarizer: nil, exportDirectory: root.appendingPathComponent("export")))
        let recordings = recordings
        controller = MeetingSessionController(store: store, pipeline: pipeline, configuration: configuration, makeRecording: { options in
            let recording = TerminationFakeRecording(options: options, originOffset: originOffset)
            recordings.items.withLock { $0.append(recording) }
            return recording
        })
    }

    var lastRecording: TerminationFakeRecording? { recordings.items.withLock { $0.last } }

    func waitForState(_ state: SessionState) async throws {
        for _ in 0..<200 {
            if await controller.state == state { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// 録音の途中で落ちた会議（録音中の行と、録れた音声）を作る。
private func interruptedMeeting(store: Store, root: URL, phase: RecordingPhase?, seconds: Double?, origin: Date) throws -> MeetingRecord {
    let audio = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    if let seconds {
        try AudioFileTools.writeWAV(samples: Array(repeating: 0.1, count: Int(seconds * 16_000)), sampleRate: 16_000, to: audio.appendingPathComponent(RecordingSession.systemSTTName))
    }
    try phase?.write(in: audio)
    return try store.createMeeting(MeetingRecord(title: "架空の定例", startedAt: origin, privacyMode: .localOnly, status: .recording, audioDir: audio.path, recordingStartedAt: origin))
}

@Suite("録音中の終了・更新・異常終了（SPEC §6.4）")
struct TerminationTests {
    // MARK: 終了の求め

    private func quitEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEQuitApplication, targetDescriptor: nil,
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    @Test("ログアウト・再起動・システム終了の理由がある終了だけを、確かめない終了にする")
    func quitRequest() {
        #expect(QuitRequest(event: nil) == .user)  // ⌘Q・メニュー
        #expect(QuitRequest(event: quitEvent()) == .user)  // Dock・更新（NSRunningApplication.terminate）
        for reason in [kAEReallyLogOut, kAEShutDown, kAERestart, kAEQuitAll] {
            let event = quitEvent()
            event.setAttribute(NSAppleEventDescriptor(enumCode: OSType(reason)), forKeyword: AEKeyword(kAEQuitReason))
            #expect(QuitRequest(event: event) == .system)
        }
        let asParameter = quitEvent()
        asParameter.setParam(NSAppleEventDescriptor(enumCode: OSType(kAEShutDown)), forKeyword: AEKeyword(kAEQuitReason))
        #expect(QuitRequest(event: asParameter) == .system)
        let open = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication, targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        #expect(QuitRequest(event: open) == .user)
    }

    // MARK: 録れた長さ

    @Test("閉じる前に終わった WAV も、データ部の実際の長さで秒数を数える")
    func recordedSeconds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-wav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent(RecordingSession.systemSTTName)
        try AudioFileTools.writeWAV(samples: Array(repeating: 0.1, count: 32_000), sampleRate: 16_000, to: wav)
        #expect(abs((InterruptedWAVRecovery.recordedSeconds(wav) ?? 0) - 2) < 0.001)
        // サイズ欄が 0 のまま、データが 0.5 秒ぶん書き足された（閉じる前に終わった）
        var bytes = try Data(contentsOf: wav)
        let data = try #require(bytes.range(of: Data("data".utf8)))
        bytes.replaceSubrange((data.upperBound)..<(data.upperBound + 4), with: Data(count: 4))
        bytes.append(Data(count: 16_000))
        try bytes.write(to: wav)
        #expect(abs((InterruptedWAVRecovery.recordedSeconds(wav) ?? 0) - 2.5) < 0.001)
        #expect(InterruptedWAVRecovery.recordedSeconds(root.appendingPathComponent("missing.wav")) == nil)
        try Data("not a wav".utf8).write(to: wav)
        #expect(InterruptedWAVRecovery.recordedSeconds(wav) == nil)
    }

    // MARK: 落ちたあとの起動

    @Test("録音準備だけで落ちた録音は、送らずに行と音声を消す")
    func recoveryDiscardsArmed() throws {
        let f = try TerminationFixture(); defer { f.cleanup() }
        let meeting = try interruptedMeeting(store: f.store, root: f.root, phase: .armed, seconds: 3, origin: Date(timeIntervalSince1970: 1_800_000_000))
        let audioDir = try #require(meeting.audioDir)
        #expect(try f.store.recoverInterruptedMeetings() == [meeting.id])
        #expect(try f.store.meeting(id: meeting.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: audioDir))
        #expect(try f.store.postProcessingJobs().isEmpty)
    }

    @Test("会議の途中で落ちた録音は、録れた長さで終了時刻を決めて後処理を依頼する")
    func recoveryProcessesMeeting() throws {
        let f = try TerminationFixture(); defer { f.cleanup() }
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = try interruptedMeeting(store: f.store, root: f.root, phase: .meeting, seconds: 3, origin: origin)
        try f.store.recoverInterruptedMeetings()
        let recovered = try #require(try f.store.meeting(id: meeting.id))
        #expect(recovered.meetingStatus == .finalizing)
        #expect(recovered.endedAt == origin.addingTimeInterval(3))
        #expect(try f.store.postProcessingJobs().map(\.meetingId) == [meeting.id])
        #expect(try f.store.postProcessingJobs().first?.jobStatus == .queued)
        #expect(try f.store.latestRun(meetingId: meeting.id, step: "recovery")?.runStatus == .ok)
        // 依頼のある会議は、次の起動で同じ依頼を待ちに戻すだけ（二重に依頼しない）
        try f.store.recoverInterruptedMeetings()
        #expect(try f.store.postProcessingJobs().count == 1)
    }

    @Test("印のない録音（以前の版）は中断として残し、終了時刻だけを録れた長さにする")
    func recoveryKeepsUnmarkedAsFailed() throws {
        let f = try TerminationFixture(); defer { f.cleanup() }
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = try interruptedMeeting(store: f.store, root: f.root, phase: nil, seconds: 3, origin: origin)
        try f.store.recoverInterruptedMeetings()
        let recovered = try #require(try f.store.meeting(id: meeting.id))
        #expect(recovered.meetingStatus == .failed)
        #expect(recovered.endedAt == origin.addingTimeInterval(3))
        #expect(try f.store.latestRun(meetingId: meeting.id, step: "recovery")?.runStatus == .failed)
        #expect(try f.store.postProcessingJobs().isEmpty)
    }

    @Test("会議の印があっても WAV が読めなければ、中断として残す")
    func recoveryKeepsMeetingWithoutWAV() throws {
        let f = try TerminationFixture(); defer { f.cleanup() }
        let meeting = try interruptedMeeting(store: f.store, root: f.root, phase: .meeting, seconds: nil, origin: Date(timeIntervalSince1970: 1_800_000_000))
        let audioDir = try #require(meeting.audioDir)
        // 閉じる前に終わった AAC（読めない）だけが残った
        try Data(count: 1_000).write(to: URL(fileURLWithPath: audioDir).appendingPathComponent(RecordingSession.systemArchiveName))
        try f.store.recoverInterruptedMeetings()
        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .failed)
        #expect(try f.store.postProcessingJobs().isEmpty)
    }

    @Test("録音が始まる前に落ちた（音声も字幕もない）行は消す")
    func recoveryDiscardsEmpty() throws {
        let f = try TerminationFixture(); defer { f.cleanup() }
        let meeting = try interruptedMeeting(store: f.store, root: f.root, phase: nil, seconds: nil, origin: Date(timeIntervalSince1970: 1_800_000_000))
        let withoutFolder = try f.store.createMeeting(MeetingRecord(title: "許可を待っていた", startedAt: Date(), privacyMode: .cloudOk, status: .recording,
                                                                    audioDir: f.root.appendingPathComponent("never-created").path))
        try f.store.recoverInterruptedMeetings()
        #expect(try f.store.meeting(id: meeting.id) == nil)
        #expect(try f.store.meeting(id: withoutFolder.id) == nil)
    }

    // MARK: 録音の制御

    @Test("録音の原点を、実際に録音が始まった時刻に直す（許可の確認で待った分を開始の時刻に入れない）")
    func originFollowsActualStart() async throws {
        // 行を作ってから録音が始まるまでに 10 分かかった（録音の原点は、行を作った時刻の 10 分前ではなく後になる場合も同じ）
        let f = try TerminationFixture(originOffset: -600); defer { f.cleanup() }
        try await f.controller.start(.init(title: "架空の定例", privacyMode: .localOnly))
        let started = try #require(f.lastRecording?.startedAt)
        let id = try #require(await f.controller.currentMeeting?.id)
        let meeting = try #require(try f.store.meeting(id: id))
        let origin = try #require(meeting.recordingStartedAt)
        #expect(abs(origin.timeIntervalSince(started)) < 1)
        #expect(abs(meeting.startedAt.timeIntervalSince(started)) < 1)
        #expect(meeting.meetingStartOffsetSeconds == 0)
        // 画面の会議も同じ原点を見る
        #expect(abs((await f.controller.currentMeeting?.startedAt ?? .distantPast).timeIntervalSince(started)) < 1)
        await f.controller.stop()
    }

    @Test("録音のフォルダに、録音準備か会議かの印を残す")
    func phaseMarker() async throws {
        let f = try TerminationFixture(); defer { f.cleanup() }
        try await f.controller.arm(.init(title: "架空の定例", privacyMode: .localOnly))
        let armed = try #require(f.lastRecording)
        #expect(RecordingPhase.read(in: armed.options.outputDirectory) == .armed)
        armed.active.withLock { $0 = true }
        try await f.waitForState(.recording)
        #expect(await f.controller.state == .recording)
        #expect(RecordingPhase.read(in: armed.options.outputDirectory) == .meeting)
        await f.controller.stop()

        try await f.controller.start(.init(title: "架空の 1on1", privacyMode: .localOnly))
        let manual = try #require(f.lastRecording)
        #expect(RecordingPhase.read(in: manual.options.outputDirectory) == .meeting)
        await f.controller.stop()
    }

    @Test("終了のために止めた録音は、後処理の依頼だけを残し、後処理を始めない")
    func stopForTerminationKeepsJobQueued() async throws {
        let f = try TerminationFixture(); defer { f.cleanup() }
        try await f.controller.start(.init(title: "架空の定例", privacyMode: .localOnly))
        let id = try #require(await f.controller.currentMeeting?.id)
        await f.controller.stopForTermination()
        #expect(await f.controller.state == .idle)
        #expect(f.lastRecording?.stopped.withLock { $0 } == 1)
        #expect(try f.store.meeting(id: id)?.meetingStatus == .finalizing)
        #expect(try f.store.meeting(id: id)?.endedAt != nil)
        // 後処理を始めていれば、偽の文字起こしですぐ終わって依頼が消える
        try await Task.sleep(for: .milliseconds(300))
        #expect(try f.store.postProcessingJobs().map(\.jobStatus) == [.queued])
        // 終了の途中は、新しい録音を始めない
        await #expect(throws: AudioCaptureError.self) { try await f.controller.start(.init(title: "次", privacyMode: .localOnly)) }
    }

    @Test("終了のときの録音準備は、会議を残さずに取りやめる")
    func stopForTerminationDiscardsArmed() async throws {
        let f = try TerminationFixture(); defer { f.cleanup() }
        try await f.controller.arm(.init(title: "架空の定例", privacyMode: .localOnly))
        let id = try #require(await f.controller.currentMeeting?.id)
        let directory = try #require(f.lastRecording).options.outputDirectory
        await f.controller.stopForTermination()
        #expect(await f.controller.state == .idle)
        #expect(try f.store.meeting(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try f.store.postProcessingJobs().isEmpty)
    }

    // MARK: 更新の再起動

    @MainActor
    @Test("録音中・後処理の実行中は更新の再起動を遅らせ、空いたまま少し経ってから続ける")
    func relaunchGate() async throws {
        let gate = RelaunchGate(settle: .milliseconds(50))
        let calls = Mutex(0)
        #expect(!gate.shouldPostpone { calls.withLock { $0 += 1 } })
        #expect(!gate.isPostponed)
        gate.setBusy(true)
        #expect(gate.shouldPostpone { calls.withLock { $0 += 1 } })
        // 録音が終わってすぐ後処理が始まった（空いたのは一瞬）
        gate.setBusy(false)
        gate.setBusy(true)
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls.withLock { $0 } == 0)
        #expect(gate.isPostponed)
        gate.setBusy(false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls.withLock { $0 } == 1)
        #expect(!gate.isPostponed)
        // 続けたあとは、もう呼ばない
        gate.setBusy(true)
        gate.setBusy(false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(calls.withLock { $0 } == 1)
    }
}
