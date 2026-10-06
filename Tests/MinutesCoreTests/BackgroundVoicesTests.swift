import Foundation
import GRDB
import Testing
@testable import MinutesCore

/// 背景の声（相手のマイクが拾った周りの会話）の見分けと、話者単位の除外（2026-10-05）。
@Suite("背景の声")
struct BackgroundVoicesTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-background-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 区間ごとに大きさの違う 440 Hz（16 kHz mono）。
    private func tones(_ parts: [(seconds: Double, amplitude: Float)]) -> [Float] {
        var samples: [Float] = []
        for part in parts {
            let offset = samples.count
            samples += (0..<Int(part.seconds * 16_000)).map { part.amplitude * Float(sin(2 * Double.pi * 440 * Double(offset + $0) / 16_000)) }
        }
        return samples
    }

    /// 振幅 `amplitude` の正弦波の RMS（dBFS）。
    private func level(_ amplitude: Double) -> Double {
        20 * log10(amplitude / 2.squareRoot())
    }

    @Test("相手側の話者ごとの音量を測り、いちばん長く話した話者より 10 dB 以上小さい話者を候補にする")
    func measureAndSuggest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // 0〜4 秒: 本人、4〜6 秒: 周りの会話（20 dB 小さい）、6〜8 秒: もう 1 人の参加者（3.5 dB 小さい）
        try AudioFileTools.writeWAV(samples: tones([(4, 0.3), (2, 0.03), (2, 0.2)]), sampleRate: 16_000, to: root.appendingPathComponent(RecordingSession.systemSTTName))
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "t", startedAt: Date(), privacyMode: .cloudOk, status: .done, audioDir: root.path))
        func segment(_ start: Double, _ end: Double, _ label: String) -> SegmentRecord {
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: start, tEnd: end, clusterLabel: label, text: "\(label) \(start)")
        }
        try store.saveTranscript(meetingId: meeting.id, segments: [
            segment(0, 2, "spk_0"), segment(2, 4, "spk_0"),
            // 0.8 秒未満の断片（大きい声にかかっている）は、長い発話があれば話者の音量に使わない
            segment(3.7, 4.2, "spk_1"), segment(4, 5, "spk_1"), segment(5, 6, "spk_1"),
            segment(6, 8, "spk_2"),
            segment(0, 3, "me"),
        ], speakers: ["spk_0", "spk_1", "spk_2", "me"].map { SpeakerRecord(meetingId: meeting.id, clusterLabel: $0) })
        #expect(try BackgroundVoices.measureAndStore(store: store, meetingId: meeting.id, audioDirectory: root) == 3)
        let speakers = try store.speakers(meetingId: meeting.id)
        let host = try #require(speakers.first { $0.clusterLabel == "spk_0" })
        let background = try #require(speakers.first { $0.clusterLabel == "spk_1" })
        let other = try #require(speakers.first { $0.clusterLabel == "spk_2" })
        let me = try #require(speakers.first { $0.clusterLabel == "me" })
        #expect(abs(try #require(host.levelDb) - level(0.3)) < 0.5)
        #expect(abs(try #require(background.levelDb) - level(0.03)) < 0.5)
        #expect(abs(try #require(other.levelDb) - level(0.2)) < 0.5)
        #expect(me.levelDb == nil)

        let segments = try store.segments(meetingId: meeting.id, source: .final)
        let relative = BackgroundVoices.relativeLevels(speakers: speakers, segments: segments)
        #expect(relative[host.id] == 0)
        #expect(abs(try #require(relative[background.id]) + 20) < 0.5)
        #expect(relative[me.id] == nil)
        #expect(Set(BackgroundVoices.candidates(speakers: speakers, segments: segments).keys) == [background.id])
        // 名前を割り当てた話者・除外した話者は候補にしない
        try store.assignSpeaker(meetingId: meeting.id, clusterLabel: "spk_1", personId: nil, displayName: "佐藤")
        #expect(BackgroundVoices.candidates(speakers: try store.speakers(meetingId: meeting.id), segments: segments).isEmpty)
        try store.assignSpeaker(meetingId: meeting.id, clusterLabel: "spk_1", personId: nil, displayName: nil)
        try store.setSpeakerExcluded(meetingId: meeting.id, speakerId: background.id, excluded: true)
        #expect(BackgroundVoices.candidates(speakers: try store.speakers(meetingId: meeting.id), segments: segments).isEmpty)
        // 相手側の音声がなければ何もしない
        let empty = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(try BackgroundVoices.measureAndStore(store: store, meetingId: meeting.id, audioDirectory: empty) == 0)
        #expect(try store.speakers(meetingId: meeting.id).first { $0.clusterLabel == "spk_0" }?.levelDb != nil)
    }

    @Test("候補の基準は、除外していない話者のうちいちばん長く話した話者")
    func referenceSkipsExcluded() {
        let segments = [
            SegmentRecord(meetingId: "m", source: .final, tStart: 0, tEnd: 30, clusterLabel: "spk_0", text: "周りの会話"),
            SegmentRecord(meetingId: "m", source: .final, tStart: 30, tEnd: 40, clusterLabel: "spk_1", text: "本人"),
            SegmentRecord(meetingId: "m", source: .final, tStart: 40, tEnd: 45, clusterLabel: "spk_2", text: "別の周りの会話"),
        ]
        var speakers = [
            SpeakerRecord(id: "a", meetingId: "m", clusterLabel: "spk_0", levelDb: -30),
            SpeakerRecord(id: "b", meetingId: "m", clusterLabel: "spk_1", levelDb: -15),
            SpeakerRecord(id: "c", meetingId: "m", clusterLabel: "spk_2", levelDb: -28),
        ]
        // 周りの会話がいちばん長いと、それが基準になって候補は出ない
        #expect(BackgroundVoices.candidates(speakers: speakers, segments: segments).isEmpty)
        // 除外すると、参加者を基準に比べ直す
        speakers[0].excluded = true
        #expect(BackgroundVoices.relativeLevels(speakers: speakers, segments: segments)["b"] == 0)
        #expect(Set(BackgroundVoices.candidates(speakers: speakers, segments: segments).keys) == ["c"])
    }

    @Test("話者をすべて除外した会議は、空の本文で要約を呼ばない")
    func summaryNeedsRemainingSegments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "t", startedAt: Date(), privacyMode: .cloudOk, status: .done))
        try store.saveTranscript(meetingId: meeting.id, segments: [
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 2, clusterLabel: "spk_0", text: "周りの会話"),
        ], speakers: [SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_0")])
        let speaker = try #require(try store.speakers(meetingId: meeting.id).first)
        try store.setSpeakerExcluded(meetingId: meeting.id, speakerId: speaker.id, excluded: true)
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: FakeTranscriber(id: "local", runsLocally: true, segments: []), summarizer: FakeSummarizer(), exportDirectory: root))
        await #expect(throws: PipelineError.self) { try await pipeline.regenerateSummary(meetingId: meeting.id) }
        #expect(try store.notes(meetingId: meeting.id) == nil)
    }

    @Test("区間の音量: 音声より後ろは測らず、長さ 0 でも 1 窓は測る。パーセンタイルは線形補間")
    func segmentLevel() throws {
        let frames = (0..<100).map { -Double($0) }
        #expect(BackgroundVoices.segmentLevel(frames, start: 10, end: 11) == nil)
        #expect(BackgroundVoices.segmentLevel(frames, start: 0.5, end: 0.5) == -25)
        #expect(BackgroundVoices.percentile([4, 1, 3, 2], 0.5) == 2.5)
        #expect(abs(try #require(BackgroundVoices.percentile([1, 2, 3, 4], 0.9)) - 3.7) < 1e-9)
        #expect(BackgroundVoices.percentile([], 0.5) == nil)
    }

    @Test("除外した話者の発話は要約・検索・書き出しから外れ、発話単位で移した発話も同じに扱う。戻せば元どおり")
    func exclusion() throws {
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "定例", startedAt: Date(), privacyMode: .cloudOk, status: .done))
        try store.saveTranscript(meetingId: meeting.id, segments: [
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 1, clusterLabel: "spk_0", text: "予算の議論です"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 1, tEnd: 2, clusterLabel: "spk_1", text: "隣の席の雑談です"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 2, tEnd: 3, clusterLabel: "spk_1", text: "雑談の続きです"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 3, tEnd: 4, clusterLabel: "spk_0", text: "予算の雑談です"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 4, tEnd: 5, clusterLabel: "me", text: "了解です"),
        ], speakers: ["spk_0", "spk_1", "me"].map { SpeakerRecord(meetingId: meeting.id, clusterLabel: $0) })
        let speakers = try store.speakers(meetingId: meeting.id)
        let host = try #require(speakers.first { $0.clusterLabel == "spk_0" })
        let background = try #require(speakers.first { $0.clusterLabel == "spk_1" })
        let ids = try store.segments(meetingId: meeting.id, source: .final).compactMap(\.id)
        // 背景の声のクラスタに紛れた本人の発言は本人へ、本人のクラスタに紛れた周りの会話は背景の声へ移す
        try store.overrideSegmentSpeaker(segmentId: ids[2], meetingId: meeting.id, speakerId: host.id)
        try store.overrideSegmentSpeaker(segmentId: ids[3], meetingId: meeting.id, speakerId: background.id)
        try store.setSpeakerExcluded(meetingId: meeting.id, speakerId: background.id, excluded: true)
        let kept = [ids[0], ids[2], ids[4]]

        // 要約: 発話も話者名も渡さない。発話は DB に残る
        let input = try store.summaryInput(meetingId: meeting.id)
        #expect(input.segments.map(\.id) == kept.map(Int.init))
        #expect(input.speakerNames["spk_1"] == nil)
        #expect(try store.segments(meetingId: meeting.id, source: .final).count == 5)
        // 検索: 2 文字（LIKE）と 3 文字以上（FTS）。前後 1 件にも出さない
        #expect(try store.search("雑談").first?.segmentHits.map(\.segment.id) == [ids[2]])
        let hits = try #require(try store.search("予算の").first?.segmentHits)
        #expect(hits.map(\.segment.id) == [ids[0]])
        #expect(hits.first?.context.map(\.id) == [ids[0], ids[2]])
        #expect(try store.search("の雑談").isEmpty)
        // 書き出し: 発話も話者の一覧も書かない
        let bundle = try store.withCloudExport(meetingId: meeting.id) { try MeetingExporter.build($0) }
        let transcript = try JSONCoding.decoder().decode(TranscriptDocument.self, from: try #require(bundle.files.first { $0.name == "transcript.json" }?.data))
        #expect(transcript.segments.map(\.id) == kept.map(Int.init))
        #expect(transcript.speakers.map(\.label) == ["me", "spk_0"])
        let markdown = String(decoding: try #require(bundle.files.first { $0.name == "meeting.md" }?.data), as: UTF8.self)
        #expect(!markdown.contains("雑談です"))
        #expect(markdown.contains("雑談の続きです"))
        #expect(!markdown.contains("spk_1"))

        // 話者を保存し直しても（再処理）除外と音量は残る
        try store.setSpeakerLevels(meetingId: meeting.id, levels: ["spk_1": -30])
        try store.replaceSpeakers(meetingId: meeting.id, with: ["spk_0", "spk_1", "me"].map { SpeakerRecord(meetingId: meeting.id, clusterLabel: $0) })
        let resaved = try #require(try store.speakers(meetingId: meeting.id).first { $0.clusterLabel == "spk_1" })
        #expect(resaved.excluded)
        #expect(resaved.levelDb == -30)
        // 戻すと元どおり
        try store.setSpeakerExcluded(meetingId: meeting.id, speakerId: background.id, excluded: false)
        #expect(try store.summaryInput(meetingId: meeting.id).segments.count == 5)
        #expect(try store.search("の雑談").first?.segmentHits.count == 2)
        #expect(throws: StoreError.self) { try store.setSpeakerExcluded(meetingId: "other", speakerId: background.id, excluded: true) }
    }

    @Test("後処理の話者の対応付けで相手側の話者の音量を保存し、背景の声を候補にする")
    func pipelineMeasuresLevels() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: tones([(4, 0.3), (2, 0.03)]), sampleRate: 16_000, to: audio.appendingPathComponent(RecordingSession.systemSTTName))
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "定例", startedAt: Date(), privacyMode: .cloudOk, status: .finalizing, audioDir: audio.path))
        let local = FakeTranscriber(id: "local.fake", runsLocally: true, segments: [
            TranscriptSegment(start: 0, end: 4, text: "本題です", speakerLabel: "S1"),
            TranscriptSegment(start: 4, end: 6, text: "周りの会話", speakerLabel: "S2"),
        ])
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: local, summarizer: nil, exportDirectory: root.appendingPathComponent("export")))
        _ = try await pipeline.run(meetingId: meeting.id)
        let speakers = try store.speakers(meetingId: meeting.id)
        #expect(speakers.filter { $0.levelDb != nil }.map(\.clusterLabel).sorted() == ["spk_0", "spk_1"])
        let candidates = BackgroundVoices.candidates(speakers: speakers, segments: try store.segments(meetingId: meeting.id, source: .final))
        #expect(candidates.keys.compactMap { id in speakers.first { $0.id == id }?.clusterLabel } == ["spk_1"])
    }

    @Test("音量を測る前に処理した会議は、開いたときに残っている音声から測る")
    @MainActor
    func detailBackfillsLevels() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try AudioFileTools.writeWAV(samples: tones([(4, 0.3), (2, 0.03)]), sampleRate: 16_000, to: root.appendingPathComponent(RecordingSession.systemSTTName))
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "t", startedAt: Date(), privacyMode: .cloudOk, status: .done, audioDir: root.path))
        try store.saveTranscript(meetingId: meeting.id, segments: [
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 4, clusterLabel: "spk_0", text: "本題です"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 4, tEnd: 6, clusterLabel: "spk_1", text: "周りの会話"),
        ], speakers: ["spk_0", "spk_1"].map { SpeakerRecord(meetingId: meeting.id, clusterLabel: $0) })
        let detail = MeetingDetailModel(store: store, pipeline: nil, meetingId: meeting.id, notesDraft: UserNotesDraft { _ in }, voicesDirectory: root)
        detail.reload()
        // 測定は裏で走る。保存されるまで待つ
        var waits = 0
        while try store.speakers(meetingId: meeting.id).allSatisfy({ $0.levelDb == nil }), waits < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waits += 1
        }
        detail.reload()
        #expect(detail.backgroundCandidates.keys.compactMap { id in detail.speakers.first { $0.id == id }?.clusterLabel } == ["spk_1"])
        let background = try #require(detail.speakers.first { $0.clusterLabel == "spk_1" })
        detail.setExcluded(background, excluded: true)
        #expect(detail.isExcluded(try #require(detail.segments.last)))
        #expect(!detail.isExcluded(try #require(detail.segments.first)))
        #expect(detail.backgroundCandidates.isEmpty)
    }

    @Test("v6 の DB の話者は、除外なし・音量なしで v7 に上がる")
    func migrationFromV6() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("v6.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try StoreSchema.migrator().migrate(queue, upTo: "v6_meeting_tags")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO meetings(id, title, started_at, privacy_mode, status, created_at, updated_at) VALUES ('m', 't', '2026-10-05T00:00:00Z', 'cloud_ok', 'done', '2026-10-05T00:00:00Z', '2026-10-05T00:00:00Z')")
            try db.execute(sql: "INSERT INTO speakers(id, meeting_id, cluster_label, display_name) VALUES ('s', 'm', 'spk_0', '田中')")
        }
        let store = try Store.open(at: url)
        let speaker = try #require(try store.speakers(meetingId: "m").first)
        #expect(speaker.displayName == "田中")
        #expect(!speaker.excluded)
        #expect(speaker.levelDb == nil)
    }
}
