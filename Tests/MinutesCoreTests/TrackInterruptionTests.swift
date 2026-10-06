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

    // MARK: - Helpers

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
