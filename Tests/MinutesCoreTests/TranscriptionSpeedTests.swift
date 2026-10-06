import Foundation
import Synchronization
import Testing
@testable import MinutesCore

/// 各トラックの送信が重なったかを数える（G3: system と mic を同時に送る）。
private final class ConcurrencyProbeTranscriber: BatchTranscriber, Sendable {
    let id = "cloud.fake"
    let runsLocally = false
    private let state = Mutex((inFlight: 0, maxInFlight: 0))

    var maxInFlight: Int { state.withLock { $0.maxInFlight } }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        state.withLock { $0.inFlight += 1; $0.maxInFlight = max($0.maxInFlight, $0.inFlight) }
        try await Task.sleep(for: .milliseconds(200))
        state.withLock { $0.inFlight -= 1 }
        let meta = UploadTiming(uploadSeconds: 12.5, serverSeconds: 3.25, bytesSent: 1_000_000).metadata
        return TranscriptionResult(segments: [TranscriptSegment(start: 0, end: 2, text: "こんにちは", speakerLabel: request.diarize ? "speaker_0" : nil)], providerMeta: meta)
    }
}

@Suite("議事録までの時間（G3）")
struct TranscriptionSpeedTests {
    @Test("送信用の FLAC はサンプルを変えずに WAV より小さくなる")
    func flacIsLossless() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-flac-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // 発話と無音が交互の 10 秒（会議音声に近い）
        let samples: [Float] = (0..<160_000).map { i in
            (i / 16_000) % 2 == 0 ? Float(sin(Double(i) * 2 * .pi * 220 / 16_000) * 0.25) : 0
        }
        let wav = directory.appendingPathComponent("system_16k.wav")
        try AudioFileTools.writeWAV(samples: samples, sampleRate: 16_000, to: wav)
        let flac = try AudioFileTools.flacCopy(of: wav)
        defer { try? FileManager.default.removeItem(at: flac.deletingLastPathComponent()) }
        #expect(flac.pathExtension == "flac")
        #expect(try AudioFileTools.fileSize(flac) < AudioFileTools.fileSize(wav))
        let original = try AudioFileTools.loadMono16k(wav)
        let restored = try AudioFileTools.loadMono16k(flac)
        #expect(original.count == restored.count)
        #expect(zip(original, restored).allSatisfy { $0 == $1 })
    }

    @Test("system と mic を同時に文字起こしし、送信と処理の時間を記録に残す")
    func tracksRunConcurrently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-speed-" + UUID().uuidString)
        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tone = (0..<64_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000) * 0.3) }
        try AudioFileTools.writeWAV(samples: tone, sampleRate: 16_000, to: audioDir.appendingPathComponent(RecordingSession.systemSTTName))
        try AudioFileTools.writeWAV(samples: tone, sampleRate: 16_000, to: audioDir.appendingPathComponent(RecordingSession.micSTTName))
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "定例", startedAt: Date(), privacyMode: .cloudOk, status: .finalizing, audioDir: audioDir.path))
        let cloud = ConcurrencyProbeTranscriber()
        let providers = PipelineProviders(cloud: cloud, local: FakeTranscriber(id: "local.fake", runsLocally: true, segments: []),
                                          summarizer: FakeSummarizer(), exportDirectory: root.appendingPathComponent("export"))
        _ = try await PostProcessPipeline(store: store, providers: providers).run(meetingId: meeting.id)

        #expect(cloud.maxInFlight == 2)
        let note = try store.latestRun(meetingId: meeting.id, step: "transcribe_final")?.provider
        #expect(note == "system: cloud.fake (送信 12.5 s・処理 3.2 s); mic: cloud.fake (送信 12.5 s・処理 3.2 s)")
    }

    @Test("送信速度は送ったバイト数と送信時間から出す")
    func uploadSpeed() {
        let timing = UploadTiming(uploadSeconds: 8, serverSeconds: 20, bytesSent: 10_000_000)
        #expect(timing.megabitsPerSecond == 10)
        #expect(timing.metadata["upload_mbps"] == "10.0")
        #expect(UploadTiming.note(from: [:]) == nil)
    }
}
