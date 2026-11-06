import Foundation
import Synchronization
import Testing
@testable import MinutesCore

private final class TrackRecordingTranscriber: BatchTranscriber, Sendable {
    let id = "cloud.fake"
    let runsLocally = false
    let requested = Mutex<[String]>([])

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        requested.withLock { $0.append(request.audioURL.lastPathComponent) }
        return TranscriptionResult(segments: [TranscriptSegment(start: 0, end: 2, text: "おはようございます", speakerLabel: request.diarize ? "speaker_0" : nil)], providerMeta: [:])
    }
}

@Suite("片トラックの途切れ（SPEC §4.3）")
struct TrackInterruptionTests {
    @Test("片方だけ止まったら失敗にせず、途切れと復帰を一度ずつ知らせる")
    func oneTrackStalls() {
        let watchdog = idleWatchdog()
        defer { watchdog.stop() }
        let events = Mutex<[CaptureWatchdog.Interruption]>([])
        let failures = Mutex(0)
        let record: @Sendable (CaptureWatchdog.Interruption) -> Void = { event in events.withLock { $0.append(event) } }
        let fail: @Sendable (CaptureFailure) -> Void = { _ in failures.withLock { $0 += 1 } }

        // mic は 10 秒で止まり、system は届き続けている
        watchdog.check([stats("system", lastEnd: 16), stats("mic", lastEnd: 10)], elapsed: 16, tapAutoStart: false, onInterruption: record, onFailure: fail)
        watchdog.check([stats("system", lastEnd: 20), stats("mic", lastEnd: 10)], elapsed: 20, tapAutoStart: false, onInterruption: record, onFailure: fail)
        #expect(watchdog.interruptedTracks == ["mic"])
        // mic が戻る
        watchdog.check([stats("system", lastEnd: 30), stats("mic", lastEnd: 30)], elapsed: 30, tapAutoStart: false, onInterruption: record, onFailure: fail)
        #expect(watchdog.interruptedTracks.isEmpty)
        #expect(events.withLock { $0 } == [.interrupted(track: "mic", since: 10), .recovered(track: "mic", seconds: 20)])
        #expect(failures.withLock { $0 } == 0)
    }

    @Test("作り直した入力は、作り直した時刻から途切れを数え直す")
    func restartResetsStall() {
        let watchdog = idleWatchdog()
        defer { watchdog.stop() }
        let events = Mutex<[CaptureWatchdog.Interruption]>([])
        let failures = Mutex(0)
        let record: @Sendable (CaptureWatchdog.Interruption) -> Void = { event in events.withLock { $0.append(event) } }
        let fail: @Sendable (CaptureFailure) -> Void = { _ in failures.withLock { $0 += 1 } }

        // 機器の切り替えで両トラックとも 10 秒で音声が止まり、mic は 13 秒、system は 14 秒に作り直した
        let tracks = [stats("system", lastEnd: 10), stats("mic", lastEnd: 10)]
        watchdog.noteRestart(track: "mic", at: 13)
        watchdog.noteRestart(track: "system", at: 14)
        // 切り替え前の最後の音声から数えると、ここで両方とも 5 秒を超えて失敗になる
        watchdog.check(tracks, elapsed: 16, tapAutoStart: false, onInterruption: record, onFailure: fail)
        #expect(watchdog.interruptedTracks.isEmpty)
        // 作り直した mic から 5 秒届かなければ途切れ。system は作り直してからまだ 5 秒たっていない
        watchdog.check(tracks, elapsed: 18.5, tapAutoStart: false, onInterruption: record, onFailure: fail)
        #expect(watchdog.interruptedTracks == ["mic"])
        #expect(failures.withLock { $0 } == 0)
        // 作り直しても両方とも届かなければ失敗にする
        watchdog.check(tracks, elapsed: 19.5, tapAutoStart: false, onInterruption: record, onFailure: fail)
        #expect(failures.withLock { $0 } == 1)
        #expect(events.withLock { $0 } == [.interrupted(track: "mic", since: 10)])
    }

    @Test("作り直しただけでは途切れから戻ったとみなさず、音声が届いてから復帰を知らせる")
    func restartDoesNotRecover() {
        let watchdog = idleWatchdog()
        defer { watchdog.stop() }
        let events = Mutex<[CaptureWatchdog.Interruption]>([])
        let record: @Sendable (CaptureWatchdog.Interruption) -> Void = { event in events.withLock { $0.append(event) } }
        let fail: @Sendable (CaptureFailure) -> Void = { _ in Issue.record("system は届いているので失敗にしない") }
        // mic は 10 秒で止まって途切れになり、20 秒に作り直した（system は届き続けている）
        watchdog.check([stats("system", lastEnd: 16), stats("mic", lastEnd: 10)], elapsed: 16, tapAutoStart: false, onInterruption: record, onFailure: fail)
        watchdog.noteRestart(track: "mic", at: 20)
        watchdog.check([stats("system", lastEnd: 21), stats("mic", lastEnd: 10)], elapsed: 21, tapAutoStart: false, onInterruption: record, onFailure: fail)
        #expect(watchdog.interruptedTracks == ["mic"])
        // 作り直した mic から音声が届いたら、戻ったと知らせる
        watchdog.check([stats("system", lastEnd: 23), stats("mic", lastEnd: 22.5)], elapsed: 23, tapAutoStart: false, onInterruption: record, onFailure: fail)
        #expect(watchdog.interruptedTracks.isEmpty)
        #expect(events.withLock { $0 } == [.interrupted(track: "mic", since: 10), .recovered(track: "mic", seconds: 13)])
    }

    @Test("作り直したあとに音声が届いていれば、その音声から数える")
    func restartBeforeLastAudio() {
        let track = stats("mic", lastEnd: 10)
        #expect(!CaptureWatchdog.isStalled(stats: track, elapsed: 16, tapAutoStart: false, restartedAt: 13))
        #expect(CaptureWatchdog.isStalled(stats: track, elapsed: 18.5, tapAutoStart: false, restartedAt: 13))
        #expect(CaptureWatchdog.isStalled(stats: track, elapsed: 16, tapAutoStart: false, restartedAt: 4))
    }

    @Test("すべてのトラックが止まったら失敗にする", arguments: [false, true])
    func allTracksStall(singleTrack: Bool) {
        let watchdog = idleWatchdog()
        defer { watchdog.stop() }
        let failures = Mutex<[CaptureFailure]>([])
        let tracks = singleTrack ? [stats("mic", lastEnd: 12)] : [stats("system", lastEnd: 10), stats("mic", lastEnd: 12)]
        watchdog.check(tracks, elapsed: 18, tapAutoStart: false, onInterruption: { _ in }, onFailure: { failure in failures.withLock { $0.append(failure) } })
        #expect(failures.withLock { $0.count } == 1)
        #expect(failures.withLock { $0.first?.operation } == "音声入力の監視")
        let message = failures.withLock { $0.first?.message } ?? ""
        #expect(message.contains(singleTrack ? "音声データが 5 秒以上" : "すべての音声入力"))
    }

    @Test("途切れたまま終わったトラックは、停止時に末尾を無音で埋めて検証を通す")
    func tailPadding() throws {
        let t0 = HostClock.now()
        let padded = TrackPipeline(name: "mic", timelineStartHostTime: t0, archiveURL: nil, sttURL: nil, streamLiveAudio: false)
        let unpadded = TrackPipeline(name: "mic", timelineStartHostTime: t0, archiveURL: nil, sttURL: nil, streamLiveAudio: false)
        for i in 0..<20 {
            padded.enqueue(chunk(t0: t0, time: Double(i) / 10, sample: Double(i * 4800)))
            unpadded.enqueue(chunk(t0: t0, time: Double(i) / 10, sample: Double(i * 4800)))
        }
        let stats = padded.finish(padTo: 10)
        #expect(abs(stats.writtenSeconds - 10) < 0.01)
        #expect(abs((stats.tailPaddingSeconds ?? 0) - 8) < 0.01)
        #expect(stats.gapCount == 1)
        try RecordingAudioValidation.validate(stats: stats, recordingDuration: 10)
        // 埋めなければ録音の終了時刻と一致せず、会議全体が失敗扱いになる
        #expect(throws: CaptureFailure.self) { try RecordingAudioValidation.validate(stats: unpadded.finish(), recordingDuration: 10) }
    }

    @Test("最後まで音声が届いていたトラックは埋めない")
    func healthyTrackNotPadded() {
        let t0 = HostClock.now()
        let pipeline = TrackPipeline(name: "system", timelineStartHostTime: t0, archiveURL: nil, sttURL: nil, streamLiveAudio: false)
        for i in 0..<98 { pipeline.enqueue(chunk(t0: t0, time: Double(i) / 10, sample: Double(i * 4800))) }
        let stats = pipeline.finish(padTo: 10)
        #expect(stats.tailPaddingSeconds == nil)
        #expect(stats.gapCount == 0)
    }

    @Test("一度も音声が届かなかったトラックは、全体を無音のファイルにする")
    func silentTrack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-silent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent(RecordingSession.micArchiveName)
        let stt = directory.appendingPathComponent(RecordingSession.micSTTName)
        let pipeline = TrackPipeline(name: "mic", timelineStartHostTime: HostClock.now(), archiveURL: archive, sttURL: stt, streamLiveAudio: false)
        let stats = pipeline.finish(padTo: 3)
        #expect(stats.receivedFrames == 0)
        #expect(abs((stats.tailPaddingSeconds ?? 0) - 3) < 0.01)
        for url in [archive, stt] {
            let duration = try AudioFileTools.duration(of: url)
            #expect(abs(duration - 3) < 0.1)
            try RecordingAudioValidation.validate(stats: stats, fileDuration: duration, recordingDuration: 3)
        }
    }

    @Test("音声が届かなかったトラックは文字起こしに送らず、途切れを後処理の記録に残す")
    func pipelineSkipsSilentTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-interrupt-" + UUID().uuidString)
        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tone = (0..<64_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000) * 0.3) }
        try AudioFileTools.writeWAV(samples: tone, sampleRate: 16_000, to: audioDir.appendingPathComponent(RecordingSession.systemSTTName))
        try AudioFileTools.writeWAV(samples: [Float](repeating: 0, count: 64_000), sampleRate: 16_000, to: audioDir.appendingPathComponent(RecordingSession.micSTTName))
        var system = stats("system", lastEnd: 4)
        system.receivedFrames = 192_000
        system.receivedSeconds = 4
        var mic = stats("mic", lastEnd: nil)
        mic.writtenSeconds = 4
        mic.gapCount = 1
        mic.gapSeconds = 4
        mic.tailPaddingSeconds = 4
        let manifest = RecordingManifest(schemaVersion: 1, id: UUID().uuidString, title: "定例", startedAt: Date(), endedAt: Date(), durationSeconds: 4,
                                         targetBundleIdentifiers: [], allSystemAudio: false, tappedProcesses: [], clockDevice: nil, micDevice: nil, tapStream: nil,
                                         files: ["system_stt": RecordingSession.systemSTTName, "mic_stt": RecordingSession.micSTTName],
                                         tracks: ["system": system, "mic": mic], resourceUsage: nil, events: [])
        try manifest.write(to: audioDir)

        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "定例", startedAt: Date(), privacyMode: .cloudOk, status: .finalizing, audioDir: audioDir.path))
        let cloud = TrackRecordingTranscriber()
        let providers = PipelineProviders(cloud: cloud, local: FakeTranscriber(id: "local.fake", runsLocally: true, segments: []),
                                          summarizer: FakeSummarizer(), exportDirectory: root.appendingPathComponent("export"))
        _ = try await PostProcessPipeline(store: store, providers: providers).run(meetingId: meeting.id)

        #expect(cloud.requested.withLock { $0 } == [RecordingSession.systemSTTName])
        #expect(try store.latestRun(meetingId: meeting.id, step: "transcribe_final")?.provider?.contains("mic: skipped") == true)
        let finalizeNote = try store.latestRun(meetingId: meeting.id, step: "finalize_audio")?.provider
        #expect(finalizeNote == "mic: 途切れ 4 秒を無音で補完")
        #expect(try store.meeting(id: meeting.id)?.meetingStatus == .done)
    }

    @Test("入力が止まって止めた録音も、止まるまでの音声で後処理を進める", arguments: [10.0, 65_000.0])
    func pipelineAfterInputStall(recordingDuration: Double) async throws {
        // 10 秒: 最後の音声から 6 秒後に止めた。65,000 秒: スリープで停止が遅れ、録音の長さが十数時間になった
        var system = stats("system", lastEnd: 4)
        var mic = stats("mic", lastEnd: 3.9)
        system.failure = CaptureWatchdog.failure(stalled: [system, mic])
        mic.receivedFrames = 187_200
        let folder = try recordingFolder(system: system, mic: mic, duration: recordingDuration)
        defer { try? FileManager.default.removeItem(at: folder.root) }

        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "定例", startedAt: Date(), privacyMode: .cloudOk, status: .failed, audioDir: folder.audio.path))
        _ = try store.recordRun(meetingId: meeting.id, step: "capture", status: .failed, error: system.failure?.localizedDescription)
        let providers = PipelineProviders(cloud: TrackRecordingTranscriber(), local: FakeTranscriber(id: "local.fake", runsLocally: true, segments: []),
                                          summarizer: FakeSummarizer(), exportDirectory: folder.root.appendingPathComponent("export"))
        // 「後処理をやり直す」と同じ経路
        _ = try await PostProcessPipeline(store: store, providers: providers).run(meetingId: meeting.id)

        #expect(try store.meeting(id: meeting.id)?.meetingStatus == .done)
        let finalizeNote = try store.latestRun(meetingId: meeting.id, step: "finalize_audio")?.provider
        #expect(finalizeNote == "入力が止まって録音を停止（最後の音声: mic 00:00:03, system 00:00:04）")
    }

    @Test("書き込みの失敗が残った録音や、長さの合わないファイルは「音声の確認」で止める")
    func failuresStillBlockFinalize() throws {
        let store = try Store.inMemory()
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: FakeTranscriber(id: "local.fake", runsLocally: true, segments: []),
                                                                                      summarizer: nil, exportDirectory: FileManager.default.temporaryDirectory))
        var written = stats("system", lastEnd: 4)
        written.failure = CaptureFailure(track: "system", operation: "WAV 書き込み", message: "disk full")
        let broken = try recordingFolder(system: written, mic: stats("mic", lastEnd: 4), duration: 4)
        defer { try? FileManager.default.removeItem(at: broken.root) }
        let first = try store.createMeeting(MeetingRecord(title: "定例", startedAt: Date(), privacyMode: .cloudOk, status: .failed, audioDir: broken.audio.path))
        #expect(throws: CaptureFailure(track: "system", operation: "WAV 書き込み", message: "disk full")) {
            try pipeline.finalizeAudio(meeting: first, directory: broken.audio)
        }

        // 監視の失敗でも、保存したファイルが書き込んだ時間より短ければ止める
        var stalled = stats("system", lastEnd: 8)
        stalled.failure = CaptureWatchdog.failure(stalled: [stalled])
        let short = try recordingFolder(system: stalled, mic: nil, duration: 14)
        defer { try? FileManager.default.removeItem(at: short.root) }
        let second = try store.createMeeting(MeetingRecord(title: "定例", startedAt: Date(), privacyMode: .cloudOk, status: .failed, audioDir: short.audio.path))
        #expect(throws: CaptureFailure.self) { try pipeline.finalizeAudio(meeting: second, directory: short.audio) }
    }

    // MARK: - Helpers

    /// 架空の録音フォルダ。各トラックは 16 kHz の音で、長さは system 4 秒・mic 4 秒（mic を渡さなければ system だけ）。
    private func recordingFolder(system: TrackStatsSnapshot, mic: TrackStatsSnapshot?, duration: Double) throws -> (root: URL, audio: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-stall-" + UUID().uuidString)
        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let tone = (0..<64_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000) * 0.3) }
        try AudioFileTools.writeWAV(samples: tone, sampleRate: 16_000, to: audioDir.appendingPathComponent(RecordingSession.systemSTTName))
        var files = ["system_stt": RecordingSession.systemSTTName]
        var tracks = ["system": system]
        if let mic {
            try AudioFileTools.writeWAV(samples: tone, sampleRate: 16_000, to: audioDir.appendingPathComponent(RecordingSession.micSTTName))
            files["mic_stt"] = RecordingSession.micSTTName
            tracks["mic"] = mic
        }
        try JSONCoding.encoder().encode(tracks.keys.sorted()).write(to: audioDir.appendingPathComponent("expected-tracks.json"))
        let manifest = RecordingManifest(schemaVersion: 1, id: UUID().uuidString, title: "定例", startedAt: Date(), endedAt: Date(), durationSeconds: duration,
                                         targetBundleIdentifiers: [], allSystemAudio: false, tappedProcesses: [], clockDevice: nil, micDevice: nil, tapStream: nil,
                                         files: files, tracks: tracks, resourceUsage: nil, events: [])
        try manifest.write(to: audioDir)
        return (root, audioDir)
    }

    private func stats(_ name: String, lastEnd: Double?) -> TrackStatsSnapshot {
        TrackStatsSnapshot(name: name, sourceSampleRate: 48_000, sourceChannels: 1, archiveSampleRate: 48_000,
                           receivedFrames: 0, receivedSeconds: 0, writtenSeconds: lastEnd ?? 0, firstChunkOffsetSeconds: lastEnd == nil ? nil : 0,
                           gapCount: 0, gapSeconds: 0, overlapCount: 0, overlapSeconds: 0, formatChanges: 0,
                           lastRmsDb: -40, intervalPeakRmsDb: -40, activeSeconds: 0, lastChunkTimelineEnd: lastEnd)
    }

    /// タイマーを動かさず、判定（check）を直接呼ぶ監視。
    private func idleWatchdog() -> CaptureWatchdog {
        CaptureWatchdog(startTime: 0, tapAutoStart: false, interval: 3600, snapshots: { [] }, onFailure: { _ in })
    }

    private func chunk(t0: UInt64, time: Double, sample: Double) -> PCMChunk {
        PCMChunk(channels: [Array(repeating: 0.1, count: 4800)], sampleRate: 48_000,
                 hostTime: t0 + HostClock.hostTime(fromSeconds: time), sampleTime: sample)
    }
}
