import Foundation
import Testing
@testable import MinutesCore

private final class ImportTranscriber: BatchTranscriber, Sendable {
    let id = "import-fixture"
    let runsLocally = true
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        TranscriptionResult(segments: [
            .init(start: 0, end: 1, text: "対面の会議の本文", speakerLabel: "speaker_0"),
            .init(start: 1, end: 2, text: "もう一人の発言", speakerLabel: "speaker_1"),
        ], providerMeta: ["provider": id])
    }
}

private struct ImportFixture {
    let root: URL
    let store: Store
    var audioRoot: URL { root.appendingPathComponent("audio") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try Store.open(at: root.appendingPathComponent("test.sqlite"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// ボイスメモに似た 48 kHz の m4a（3 秒の正弦波）。
    func memo(named name: String = "新規録音 3.m4a", seconds: Double = 3) throws -> URL {
        let url = root.appendingPathComponent(name)
        let rate = 48_000.0
        let samples = (0..<Int(rate * seconds)).map { Float(sin(Double($0) * 2 * .pi * 440 / rate) * 0.2) }
        try AudioFileTools.writeAAC(samples: samples, sampleRate: rate, to: url, bitrate: 64_000)
        return url
    }
}

@Suite("外部の録音の取り込み（SPEC §4.4）")
struct AudioImportTests {
    @Test("音声を system トラックとして写し、処理中の会議と後処理の依頼を作る")
    func importsAsSystemTrack() async throws {
        let f = try ImportFixture(); defer { f.cleanup() }
        let source = try f.memo()
        let probe = try await AudioImport.probe(source)
        #expect(abs(probe.duration - 3) < 0.1)
        #expect(probe.recordedAt != nil)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = try AudioImport.importMeeting(
            from: source,
            details: .init(title: "対面の打ち合わせ", startedAt: start, language: .ja, privacy: .localOnly, attendees: [.init(name: "山田")]),
            store: f.store, audioRoot: f.audioRoot)

        #expect(FileManager.default.fileExists(atPath: source.path))
        let directory = try #require(meeting.audioDirectoryURL)
        #expect(directory.deletingLastPathComponent().standardizedFileURL == f.audioRoot.standardizedFileURL)
        let wav = try AudioFileTools.duration(of: directory.appendingPathComponent(RecordingSession.systemSTTName))
        let archive = try AudioFileTools.duration(of: directory.appendingPathComponent(RecordingSession.systemArchiveName))
        #expect(abs(wav - 3) < 0.1)
        #expect(abs(archive - 3) < 0.1)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(RecordingSession.micSTTName).path))

        let stored = try #require(try f.store.meeting(id: meeting.id))
        #expect(stored.meetingStatus == .finalizing)
        #expect(stored.startedAt == start)
        #expect(stored.recordingStartedAt == start)
        #expect(abs((stored.endedAt ?? start).timeIntervalSince(start) - 3) < 0.1)
        #expect(stored.language == MeetingLanguage.ja.rawValue)
        #expect(stored.attendees.map(\.name) == ["山田"])
        #expect(try f.store.postProcessingJobs().map(\.meetingId) == [meeting.id])
    }

    @Test("取り込んだ会議は録音と同じ後処理を通り、全員が相手側の話者になる")
    func runsPipeline() async throws {
        let f = try ImportFixture(); defer { f.cleanup() }
        let meeting = try AudioImport.importMeeting(
            from: try f.memo(),
            details: .init(title: "対面の打ち合わせ", startedAt: Date(), language: .ja, privacy: .localOnly),
            store: f.store, audioRoot: f.audioRoot)
        let pipeline = PostProcessPipeline(store: f.store, providers: PipelineProviders(
            cloud: nil, local: ImportTranscriber(), summarizer: nil, exportDirectory: f.root.appendingPathComponent("export")))
        let queue = PostProcessingQueue(store: f.store, pipeline: pipeline)
        await queue.start()
        await queue.waitUntilIdle()

        #expect(try f.store.meeting(id: meeting.id)?.meetingStatus == .done)
        #expect(try f.store.postProcessingJobs().isEmpty)
        let segments = try f.store.segments(meetingId: meeting.id, source: .final)
        #expect(segments.map(\.text) == ["対面の会議の本文", "もう一人の発言"])
        let speakers = try f.store.speakers(meetingId: meeting.id)
        #expect(speakers.count == 2)
        #expect(!speakers.contains { $0.clusterLabel == TrackMerger.micSpeakerLabel })
    }

    @Test("読めないファイルは会議もフォルダも作らない")
    func rejectsUnreadable() async throws {
        let f = try ImportFixture(); defer { f.cleanup() }
        let text = f.root.appendingPathComponent("memo.m4a")
        try Data("not audio".utf8).write(to: text)
        await #expect(throws: AudioImport.ImportError.unreadable("memo.m4a")) { try await AudioImport.probe(text) }
        #expect(throws: AudioImport.ImportError.unreadable("memo.m4a")) {
            try AudioImport.importMeeting(from: text, details: .init(title: "x", startedAt: Date(), language: .ja, privacy: .localOnly),
                                          store: f.store, audioRoot: f.audioRoot)
        }
        #expect(try f.store.listMeetings(.all, limit: 10).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.audioRoot.path))
    }

    @Test("録音と最も長く重なる予定を選び、少ししか重ならない予定は選ばない")
    func calendarOverlap() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let events: [(String, DateInterval)] = [
            ("直前の予定", DateInterval(start: start.addingTimeInterval(-3600), duration: 3600 + 120)),
            ("対面の打ち合わせ", DateInterval(start: start.addingTimeInterval(-300), duration: 3600)),
            ("あとの予定", DateInterval(start: start.addingTimeInterval(3000), duration: 1800)),
        ]
        #expect(AudioImport.bestOverlap(events, start: start, duration: 3600, interval: \.1)?.0 == "対面の打ち合わせ")
        // 短い録音は半分以上重なる予定だけ
        #expect(AudioImport.bestOverlap([events[0]], start: start, duration: 600, interval: \.1) == nil)
        #expect(AudioImport.bestOverlap([events[0]], start: start, duration: 200, interval: \.1)?.0 == "直前の予定")
        #expect(AudioImport.bestOverlap(events, start: start.addingTimeInterval(86_400), duration: 600, interval: \.1) == nil)
    }

    @Test("題名はファイル名から拡張子を外して作る")
    func defaultTitle() {
        #expect(AudioImport.defaultTitle(for: URL(fileURLWithPath: "/tmp/新規録音 3.m4a")) == "新規録音 3")
        #expect(AudioImport.defaultTitle(for: URL(fileURLWithPath: "/tmp/ .m4a")) == "取り込んだ録音")
    }
}
