import Foundation
import MinutesCore
import Testing

struct FakeTranscriber: BatchTranscriber {
    var id: String
    var runsLocally: Bool
    var shouldFail = false
    var segments: [TranscriptSegment]

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        if shouldFail { throw TranscriptionError.httpError(provider: id, status: 500, body: "boom", requestID: nil) }
        let label: String? = request.diarize ? "speaker_0" : nil
        return TranscriptionResult(segments: segments.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, speakerLabel: request.diarize ? ($0.speakerLabel ?? label) : nil) }, providerMeta: ["provider": id])
    }
}

struct FakeSummarizer: Summarizing {
    var modelDescription: String { "fake / prompt v0" }
    func summarize(_ input: SummaryInput) async throws -> MinutesSummary {
        let firstId = input.segments.first?.id ?? 1
        return MinutesSummary(
            summaryMd: "要約: \(input.meetingTitle)（\(input.segments.count) 発話）",
            decisions: [.init(text: "決定 A", evidence: [firstId])],
            actionItems: [.init(text: "やること", owner: "me", kind: .ownCommitment, due: nil, evidence: [firstId])],
            openQuestions: [],
            keytermsLearned: ["Nimbus"]
        )
    }
}

private struct TranscriptEchoSummarizer: Summarizing {
    var modelDescription: String { "codex/test / prompt v2" }
    func summarize(_ input: SummaryInput) async throws -> MinutesSummary {
        let first = try #require(input.segments.first)
        return MinutesSummary(summaryMd: first.text, decisions: [.init(text: "決定", evidence: [first.id])], actionItems: [.init(text: "やること", owner: "me", kind: .ownCommitment, due: nil, evidence: [first.id])], openQuestions: [], keytermsLearned: [])
    }
}

@Suite("Exporter / PostProcessPipeline")
struct ExportAndPipelineTests {
    @Test("要約のみ更新: 音声削除後も編集済み本文・ID・メモ・チェック状態を保持")
    func regenerateSummary() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "定例", startedAt: Date(), privacyMode: .cloudOk, status: .done))
        let segments = try store.appendSegments([SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 2, clusterLabel: "me", text: "人が修正した本文")])
        let id = try #require(segments.first?.id)
        let old = MinutesSummary(summaryMd: "古い要約", decisions: [], actionItems: [.init(text: "やること", owner: "me", kind: .ownCommitment, due: nil, evidence: [Int(id)], done: true)], openQuestions: [], keytermsLearned: [])
        try store.upsertNotes(NotesRecord(meetingId: meeting.id, summary: old, model: "old", userNotesMd: "ユーザーメモ"))
        let providers = PipelineProviders(cloud: nil, local: FakeTranscriber(id: "local", runsLocally: true, segments: []), summarizer: TranscriptEchoSummarizer(), exportDirectory: root)
        let pipeline = PostProcessPipeline(store: store, providers: providers)
        try await pipeline.regenerateSummary(meetingId: meeting.id)
        #expect(try store.segments(meetingId: meeting.id, source: .final) == segments)
        let notes = try #require(try store.notes(meetingId: meeting.id))
        #expect(notes.summaryMd == "人が修正した本文")
        #expect(notes.model == "codex/test / prompt v2")
        #expect(notes.userNotesMd == "ユーザーメモ")
        #expect(notes.decisions.first?.evidence == [Int(id)])
        #expect(notes.actionItems.first?.done == true)
        #expect(try store.meeting(id: meeting.id)?.meetingStatus == .done)
        #expect(try store.hasSuccessfulExport(meetingId: meeting.id))

        var restricted = meeting
        restricted.privacy = .localOnly
        try store.updateMeeting(restricted)
        await #expect(throws: PipelineError.self) { try await pipeline.regenerateSummary(meetingId: meeting.id) }
        #expect(try store.notes(meetingId: meeting.id) == notes)
    }

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func sine(seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.3 * Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
    }

    @Test("フォルダ名・slug・manifest の sha256 検証")
    func exporter() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = MeetingRecord(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV", title: "週次定例 / PJ AI", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: Date(timeIntervalSince1970: 1_800_003_600), platform: .meet, attendees: [Attendee(name: "田中", email: "t@example.com")], privacyMode: .cloudOk, status: .done)
        #expect(MeetingExporter.slug("週次定例 / PJ AI") == "週次定例-PJ-AI")
        #expect(MeetingExporter.slug("!!!") == "meeting")
        let folder = MeetingExporter.folderName(meeting: meeting)
        #expect(folder.hasSuffix("_週次定例-PJ-AI_q69g5fav"))
        let speakers = [SpeakerRecord(id: "s0", meetingId: meeting.id, clusterLabel: "spk_0", displayName: "田中"), SpeakerRecord(id: "s1", meetingId: meeting.id, clusterLabel: "me")]
        let segments = [
            SegmentRecord(id: 10, meetingId: meeting.id, source: .final, tStart: 0, tEnd: 2, speakerId: "s0", clusterLabel: "spk_0", text: "おはようございます"),
            SegmentRecord(id: 11, meetingId: meeting.id, source: .final, tStart: 2, tEnd: 4, speakerId: "s1", clusterLabel: "me", text: "よろしくお願いします"),
        ]
        let summary = MinutesSummary(summaryMd: "要約です", decisions: [.init(text: "決定", evidence: [10])], actionItems: [
            .init(text: "宿題", owner: "田中", kind: .theirTask, due: "2026-09-20", evidence: [11]),
            .init(text: "完了した仕事", owner: "me", kind: .ownCommitment, due: nil, evidence: [10], done: true),
            .init(text: "未完了の仕事", owner: "me", kind: .ownCommitment, due: nil, evidence: [11], done: false),
        ], openQuestions: [], keytermsLearned: [])
        let notes = NotesRecord(meetingId: meeting.id, summary: summary, model: "claude-sonnet-5 / prompt v1")
        let bundle = try MeetingExporter.build(.init(meeting: meeting, speakers: speakers, segments: segments, notes: notes, providerDescription: "elevenlabs.scribe_v2"))
        #expect(bundle.files.map(\.name) == ["meeting.md", "transcript.json", "summary.json"])
        let markdown = String(decoding: bundle.files[0].data, as: UTF8.self)
        #expect(markdown.hasPrefix("---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\ntitle: \"週次定例 / PJ AI\"\n"))
        #expect(markdown.contains("## 要約\n\n要約です"))
        #expect(markdown.contains("- [ ] 宿題（owner: 田中 / kind: their_task / due: 2026-09-20 / evidence: seg#11）"))
        #expect(markdown.contains("- [x] 完了した仕事"))
        #expect(markdown.contains("- [ ] 未完了の仕事"))
        #expect(markdown.contains("[00:00:00] 田中: おはようございます"))
        #expect(markdown.contains("[00:00:02] me: よろしくお願いします"))
        #expect(markdown.contains("transcript_sha256: \(bundle.manifest.files["transcript.json"]!.sha256)"))
        let written = try bundle.write(into: root)
        let verified = try ExportManifest.verify(directory: written)
        #expect(verified.meetingId == meeting.id)
        #expect(verified.files.count == 3)
        // 改ざん検知
        try Data("x".utf8).write(to: written.appendingPathComponent("summary.json"))
        #expect(throws: ExportError.self) { try ExportManifest.verify(directory: written) }
    }

    @Test("LocalDirectorySyncTarget はフォルダをコピーして checksum を返す")
    func syncTarget() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = MeetingRecord(title: "t", startedAt: Date(), privacyMode: .cloudOk, status: .done)
        let bundle = try MeetingExporter.build(.init(meeting: meeting, speakers: [], segments: [], notes: nil, providerDescription: "x"))
        let source = try bundle.write(into: root.appendingPathComponent("export"))
        let target = LocalDirectorySyncTarget(destination: root.appendingPathComponent("sync"))
        let receipt = try await target.upload(folder: source, manifest: bundle.manifest)
        #expect(receipt.checksum == bundle.manifest.checksum)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sync/\(bundle.folderName)/meeting.md").path))
    }

    @Test("パイプライン: 冪等・フォールバック・evidence の id 写像・書き出し")
    func pipeline() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: sine(seconds: 4), sampleRate: 16_000, to: audioDir.appendingPathComponent(RecordingSession.systemSTTName))
        try AudioFileTools.writeWAV(samples: sine(seconds: 4), sampleRate: 16_000, to: audioDir.appendingPathComponent(RecordingSession.micSTTName))
        let meeting = try store.createMeeting(MeetingRecord(title: "定例", startedAt: Date(), attendees: [Attendee(name: "田中")], privacyMode: .cloudOk, status: .finalizing, audioDir: audioDir.path))

        let cloud = FakeTranscriber(id: "cloud.fake", runsLocally: false, shouldFail: true, segments: [])
        let local = FakeTranscriber(id: "local.fake", runsLocally: true, segments: [
            TranscriptSegment(start: 0, end: 2, text: "おはようございます", speakerLabel: "S1"),
            TranscriptSegment(start: 2, end: 4, text: "議題に入ります", speakerLabel: "S2"),
        ])
        let syncDir = root.appendingPathComponent("sync")
        let providers = PipelineProviders(
            cloud: cloud, local: local, summarizer: FakeSummarizer(),
            exportDirectory: root.appendingPathComponent("export"),
            syncTargets: [LocalDirectorySyncTarget(destination: syncDir)]
        )
        let pipeline = PostProcessPipeline(store: store, providers: providers)
        let outcome = try await pipeline.run(meetingId: meeting.id)
        #expect(outcome.executed.count == PipelineStep.allCases.count)
        #expect(outcome.skipped.isEmpty)

        // クラウド失敗 → ローカルにフォールバックし、provider に記録される
        let transcribeRun = try #require(try store.latestRun(meetingId: meeting.id, step: "transcribe_final"))
        #expect(transcribeRun.provider?.contains("fallback") == true)
        #expect(transcribeRun.provider?.contains("local.fake") == true)

        // final segments（system 2 + mic 2）、話者、notes
        let finals = try store.segments(meetingId: meeting.id, source: .final)
        #expect(finals.count == 4)
        #expect(Set(finals.compactMap(\.clusterLabel)) == ["spk_0", "spk_1", "me"])
        let speakers = try store.speakers(meetingId: meeting.id)
        #expect(Set(speakers.map(\.clusterLabel)) == ["spk_0", "spk_1", "me"])
        let notes = try #require(try store.notes(meetingId: meeting.id))
        #expect(notes.model == "fake / prompt v0")
        let firstFinalId = try #require(finals.first?.id)
        #expect(notes.decisions[0].evidence == [Int(firstFinalId)])
        #expect(try store.keyterms() == ["Nimbus"])
        #expect(try store.meeting(id: meeting.id)?.meetingStatus == .done)

        // 書き出しと同期
        let exportPath = try #require(outcome.exportPath)
        #expect(FileManager.default.fileExists(atPath: exportPath + "/meeting.md"))
        _ = try ExportManifest.verify(directory: URL(fileURLWithPath: exportPath))
        #expect(try store.hasSuccessfulExport(meetingId: meeting.id))
        #expect((try FileManager.default.contentsOfDirectory(atPath: syncDir.path)).count == 1)

        // 再実行は完了済みステップをスキップ（notify を除く）
        let again = try await pipeline.run(meetingId: meeting.id)
        #expect(again.executed == [.notify])
        #expect(again.skipped.count == PipelineStep.allCases.count - 1)

        // force は中間成果物を消して本当にやり直す（cached にならない）
        let forced = try await pipeline.run(meetingId: meeting.id, force: [.transcribeFinal])
        #expect(forced.executed.contains(.transcribeFinal))
        let forcedRun = try #require(try store.latestRun(meetingId: meeting.id, step: "transcribe_final"))
        #expect(forcedRun.provider?.contains("cached") == false)
        #expect(forcedRun.provider?.contains("local.fake") == true)

        // local_only の会議は要約をスキップ（音声フォルダは会議ごと）
        let localAudioDir = root.appendingPathComponent("audio-local", isDirectory: true)
        try FileManager.default.createDirectory(at: localAudioDir, withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: sine(seconds: 4), sampleRate: 16_000, to: localAudioDir.appendingPathComponent(RecordingSession.systemSTTName))
        let localMeeting = try store.createMeeting(MeetingRecord(title: "秘密", startedAt: Date(), privacyMode: .localOnly, status: .finalizing, audioDir: localAudioDir.path))
        _ = try await pipeline.run(meetingId: localMeeting.id)
        #expect(try store.notes(meetingId: localMeeting.id) == nil)
        #expect(try store.latestRun(meetingId: localMeeting.id, step: "summarize")?.provider == "skipped (local_only)")
        #expect(try store.latestRun(meetingId: localMeeting.id, step: "transcribe_final")?.provider?.contains("cloud") == false)
    }

    @Test("音声保持ポリシー: export 済みで期限切れの会議だけ音声を削除する")
    func retention() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        func makeMeeting(_ name: String, daysAgo: Double, exported: Bool) throws -> MeetingRecord {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([0]).write(to: dir.appendingPathComponent(RecordingSession.systemArchiveName))
            try Data([0]).write(to: dir.appendingPathComponent(RecordingSession.systemSTTName + ".interrupted"))
            let ended = Date().addingTimeInterval(-daysAgo * 86_400)
            let meeting = try store.createMeeting(MeetingRecord(title: name, startedAt: ended.addingTimeInterval(-3600), endedAt: ended, privacyMode: .cloudOk, status: .done, audioDir: dir.path))
            if exported { _ = try store.logExport(meetingId: meeting.id, target: "local_export", status: .ok) }
            return meeting
        }
        let old = try makeMeeting("old", daysAgo: 40, exported: true)
        let recent = try makeMeeting("recent", daysAgo: 3, exported: true)
        let notExported = try makeMeeting("not-exported", daysAgo: 40, exported: false)
        let processing = try makeMeeting("processing", daysAgo: 40, exported: true)
        let lease = try store.acquireMeetingLease(processing.id)
        let report = try withExtendedLifetime(lease) { try AudioRetention.purge(store: store, retentionDays: 30) }
        #expect(report.purgedMeetingIds == [old.id])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("processing/\(RecordingSession.systemArchiveName)").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("old/\(RecordingSession.systemArchiveName)").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("recent/\(RecordingSession.systemArchiveName)").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("not-exported/\(RecordingSession.systemArchiveName)").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("old/\(RecordingSession.systemSTTName).interrupted").path))
        #expect(try store.meeting(id: old.id)?.audioDir == nil)
        #expect(try store.meeting(id: recent.id)?.audioDir != nil)
        #expect(try store.meeting(id: notExported.id)?.audioDir != nil)
    }
}
