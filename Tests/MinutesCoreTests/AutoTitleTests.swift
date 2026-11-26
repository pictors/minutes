import Foundation
import Synchronization
import Testing
@testable import MinutesCore

/// 題名も返す偽の要約。頼まれたか（suggestTitle）と、渡された題名を覚える。
private final class TitlingSummarizer: Summarizing, Sendable {
    let modelDescription = "fixture / prompt v1"
    let title: String?
    let asked = Mutex<[Bool]>([])
    let promptTitles = Mutex<[String]>([])
    let duringSummary: (@Sendable () throws -> Void)?

    init(title: String?, duringSummary: (@Sendable () throws -> Void)? = nil) {
        self.title = title
        self.duringSummary = duringSummary
    }

    func summarize(_ input: SummaryInput) async throws -> MinutesSummary {
        let first = try #require(input.segments.first)
        return MinutesSummary(summaryMd: "架空の要約", decisions: [.init(text: "決定", evidence: [first.id])], actionItems: [], openQuestions: [], keytermsLearned: [])
    }

    func summarizeWithTitle(_ input: SummaryInput, context: SummaryContext) async throws -> SummaryOutput {
        asked.withLock { $0.append(context.suggestTitle) }
        promptTitles.withLock { $0.append(input.meetingTitle) }
        try duringSummary?()
        return SummaryOutput(summary: try await summarize(input), title: context.suggestTitle ? SummaryTitle.clean(title) : nil)
    }
}

private struct TitleFixture {
    let root: URL
    let store: Store
    let meeting: MeetingRecord
    let exports: URL

    init(title: String = "Zoom 11月26日 10:00", titleAuto: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-auto-title-" + UUID().uuidString)
        let audio = root.appendingPathComponent("audio")
        exports = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: Array(repeating: 0.1, count: 16_000), sampleRate: 16_000, to: audio.appendingPathComponent(RecordingSession.systemSTTName))
        store = try Store.inMemory()
        meeting = try store.createMeeting(MeetingRecord(title: title, startedAt: Date(), privacyMode: .cloudOk, status: .finalizing, audioDir: audio.path, titleAuto: titleAuto))
    }

    func pipeline(_ summarizer: any Summarizing) -> PostProcessPipeline {
        PostProcessPipeline(store: store, providers: PipelineProviders(
            cloud: nil, local: FakeTranscriber(id: "local", runsLocally: true, segments: [.init(start: 0, end: 1, text: "架空の発言")]),
            summarizer: summarizer, exportDirectory: exports))
    }

    func current() throws -> MeetingRecord { try #require(try store.meeting(id: meeting.id)) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("題名を付けずに録った会議の題名（SPEC §8.1）")
struct AutoTitleTests {
    private struct Cases: Decodable {
        struct Case: Decodable {
            var raw: String
            var expected: String?
        }
        var maxLength: Int
        var cases: [Case]
        enum CodingKeys: String, CodingKey { case maxLength = "max_length", cases }
    }

    @Test("題名の整え方（サーバーの iPhone・Watch の会議の題名付けと同じ答えの表）")
    func sharedCases() throws {
        let url = try #require(Bundle.module.url(forResource: "summary-title-cases", withExtension: "json", subdirectory: "Fixtures"))
        let table = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
        #expect(table.cases.count >= 20 && table.maxLength == SummaryTitle.maxLength)
        for item in table.cases {
            #expect(SummaryTitle.clean(item.raw) == item.expected, "\(item.raw.prefix(30))")
        }
        #expect(SummaryTitle.clean(nil) == nil)
    }

    @Test("題名を頼むスキーマは title を足すだけで、頼まないスキーマはこれまでと同じ")
    func schema() throws {
        let plain = SummarySchema.json
        let titled = SummarySchema.json(titled: true)
        #expect((plain["properties"] as? [String: Any])?["title"] == nil)
        #expect(plain["required"] as? [String] == ["summary_md", "decisions", "action_items", "open_questions", "keyterms_learned"])
        #expect((titled["required"] as? [String])?.last == "title")
        var properties = try #require(titled["properties"] as? [String: Any])
        #expect((properties["title"] as? [String: Any])?["type"] as? String == "string")
        properties["title"] = nil
        #expect(properties as NSDictionary == plain["properties"] as? NSDictionary)
    }

    @Test("Anthropic API: 題名も頼むとツールのスキーマに title が入り、入力の title を整えて読む")
    func anthropicTool() throws {
        let tool = ClaudeSummarizer.recordMinutesTool(titled: true)
        #expect(((tool["input_schema"] as? [String: Any])?["required"] as? [String])?.contains("title") == true)
        #expect(ClaudeSummarizer.recordMinutesTool["input_schema"] as? NSDictionary == SummarySchema.json as NSDictionary)
        let response: [String: Any] = ["stop_reason": "tool_use", "content": [[
            "type": "tool_use", "name": ClaudeSummarizer.toolName,
            "input": ["summary_md": "架空の要約", "decisions": [], "action_items": [], "open_questions": [], "keyterms_learned": [], "title": "架空の価格の相談。"],
        ]]]
        let data = try JSONSerialization.data(withJSONObject: response)
        #expect(try ClaudeSummarizer.parseTitledResponse(data).title == "架空の価格の相談")
        #expect(try ClaudeSummarizer.parseResponse(data).summaryMd == "架空の要約")
    }

    private func longInput() -> SummaryInput {
        // 100 分・50 分ごとの発言（45 分で分けるので 3 つの部分になる）
        SummaryInput(meetingTitle: SummaryTitle.untitledForPrompt, startedAt: nil, attendees: [], segments: (0..<3).map {
            .init(id: $0 + 1, track: "system", tStart: Double($0) * 3000, tEnd: Double($0) * 3000 + 60, speaker: "spk_0", text: "架空の発言 \($0)")
        })
    }

    @Test("分けて要約する長い会議は、統合の依頼だけで題名を頼む（Codex・Claude Code に共通の手順）")
    func mergeOnlyStructured() async throws {
        let flags = Mutex<[Bool]>([])
        let prompt = try SummaryPrompt.loadBundled()
        let output = try await StructuredSummary.summarize(longInput(), prompt: prompt, titled: true) { _, validIds, titled in
            flags.withLock { $0.append(titled) }
            let id = try #require(validIds.min())
            return SummaryOutput(summary: MinutesSummary(summaryMd: "架空", decisions: [.init(text: "決定", evidence: [id])], actionItems: [], openQuestions: [], keytermsLearned: []),
                                 title: titled ? "統合の題名" : "部分の題名")
        }
        #expect(flags.withLock { $0 } == [false, false, false, true] && output.title == "統合の題名")
    }

    @Test("Anthropic API: 分けて要約する長い会議は、統合の依頼だけで題名を頼む")
    func mergeOnlyAnthropic() async throws {
        let titledCalls = Mutex<[Bool]>([])
        let base = StubURLProtocol.host { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
            let schema = ((body?["tools"] as? [[String: Any]])?.first?["input_schema"] as? [String: Any])?["properties"] as? [String: Any]
            let titled = schema?["title"] != nil
            titledCalls.withLock { $0.append(titled) }
            var input: [String: Any] = ["summary_md": "架空の要約", "decisions": [], "action_items": [], "open_questions": [], "keyterms_learned": []]
            if titled { input["title"] = "「架空の長い会議の題名」" }
            let response: [String: Any] = ["stop_reason": "tool_use", "content": [["type": "tool_use", "name": ClaudeSummarizer.toolName, "input": input]]]
            return (200, ["content-type": "application/json"], try! JSONSerialization.data(withJSONObject: response))
        }
        let summarizer = try ClaudeSummarizer(apiKey: "fictional-key", baseURL: base, session: StubURLProtocol.session())
        let output = try await summarizer.summarizeWithTitle(longInput(), context: SummaryContext(meetingID: "01JFICTIONAL", suggestTitle: true))
        #expect(titledCalls.withLock { $0 } == [false, false, false, true] && output.title == "架空の長い会議の題名")
        titledCalls.withLock { $0 = [] }
        #expect(try await summarizer.summarizeWithTitle(longInput(), context: SummaryContext(meetingID: "01JFICTIONAL")).title == nil)
        #expect(titledCalls.withLock { $0 } == [false, false, false, false])
    }

    @Test("題名を付けずに録った会議は、要約と同じ依頼で題名が付き、書き出しのフォルダも新しい題名になる。要約は古くならない")
    func titledByPipeline() async throws {
        let f = try TitleFixture(); defer { f.cleanup() }
        let summarizer = TitlingSummarizer(title: "「架空の価格改定の相談」。")
        let pipeline = f.pipeline(summarizer)
        let outcome = try await pipeline.run(meetingId: f.meeting.id)
        #expect(outcome.warnings.isEmpty)
        let meeting = try f.current()
        #expect(meeting.title == "架空の価格改定の相談" && meeting.titleAuto && meeting.meetingStatus == .done)
        // 仮の名前（アプリ名と日時）は要約に渡さない
        #expect(summarizer.asked.withLock { $0 } == [true] && summarizer.promptTitles.withLock { $0 } == [SummaryTitle.untitledForPrompt])
        // 保存した要約に題名は入らない
        let notes = try #require(try f.store.notes(meetingId: f.meeting.id))
        #expect(notes.summaryMd == "架空の要約")
        // 書き出しは新しい題名（古い名前のフォルダを残さない）
        let folders = try FileManager.default.contentsOfDirectory(atPath: f.exports.path).filter { !$0.hasPrefix(".") }
        #expect(folders == [MeetingExporter.folderName(meeting: meeting)])
        let markdown = try String(contentsOf: f.exports.appendingPathComponent(folders[0]).appendingPathComponent("meeting.md"), encoding: .utf8)
        #expect(markdown.contains("# 架空の価格改定の相談") && !markdown.contains("Zoom 11月26日"))
        // 題名が替わっても要約の入力は同じ: もう一度流しても要約し直さない
        let again = try await pipeline.run(meetingId: f.meeting.id)
        #expect(!again.executed.contains(.summarize) && summarizer.asked.withLock { $0 }.count == 1)
        // 人の直しとしては扱わない（サーバーへ送る直しの列に入れない）
        #expect(try f.store.pendingCloudEditPushes().isEmpty)
    }

    @Test("要約を作り直すと題名も付け直す。人が題名を直したあとは、頼まず、題名も変えない")
    func regenerateAndRename() async throws {
        let f = try TitleFixture(); defer { f.cleanup() }
        try await f.pipeline(TitlingSummarizer(title: "最初の題名")).run(meetingId: f.meeting.id)
        #expect(try f.current().title == "最初の題名")
        let second = TitlingSummarizer(title: "付け直した題名")
        try await f.pipeline(second).regenerateSummary(meetingId: f.meeting.id)
        #expect(try f.current().title == "付け直した題名" && second.asked.withLock { $0 } == [true])

        try f.store.updateMeetingTitle(id: f.meeting.id, title: "人が付けた題名")
        #expect(try f.current().titleAuto == false)
        let third = TitlingSummarizer(title: "要約の題名")
        try await f.pipeline(third).regenerateSummary(meetingId: f.meeting.id)
        #expect(try f.current().title == "人が付けた題名")
        #expect(third.asked.withLock { $0 } == [false] && third.promptTitles.withLock { $0 } == ["人が付けた題名"])
    }

    @Test("題名のある会議（予定の名前・人が付けた名前）には頼まない。要約の入力もこれまでと同じ")
    func titledMeetingUntouched() async throws {
        let f = try TitleFixture(title: "架空の週次定例", titleAuto: false); defer { f.cleanup() }
        let summarizer = TitlingSummarizer(title: "要約の題名")
        try await f.pipeline(summarizer).run(meetingId: f.meeting.id)
        #expect(try f.current().title == "架空の週次定例" && !f.current().titleAuto)
        #expect(summarizer.asked.withLock { $0 } == [false] && summarizer.promptTitles.withLock { $0 } == ["架空の週次定例"])
    }

    @Test("題名を返さない手段・使えない題名（空・「会議」）のときは、仮の名前のまま")
    func unusableTitle() async throws {
        for title in [nil, "", "会議", "「」"] as [String?] {
            let f = try TitleFixture(); defer { f.cleanup() }
            let outcome = try await f.pipeline(TitlingSummarizer(title: title)).run(meetingId: f.meeting.id)
            #expect(outcome.warnings.isEmpty)
            #expect(try f.current().title == "Zoom 11月26日 10:00" && f.current().titleAuto)
        }
        // 題名を返す口を持たない手段（既定の実装）
        let f = try TitleFixture(); defer { f.cleanup() }
        try await f.pipeline(FakeSummarizer()).run(meetingId: f.meeting.id)
        #expect(try f.current().title == "Zoom 11月26日 10:00")
        #expect(try f.store.notes(meetingId: f.meeting.id)?.summaryMd?.contains(SummaryTitle.untitledForPrompt) == true)
    }

    @Test("要約のあいだに人が題名を直したら、その題名を残す（要約は入力が変わったので保存しない）")
    func renameDuringSummary() async throws {
        let f = try TitleFixture(); defer { f.cleanup() }
        let store = f.store
        let id = f.meeting.id
        let summarizer = TitlingSummarizer(title: "要約の題名") { try store.updateMeetingTitle(id: id, title: "要約のあいだに付けた題名") }
        let outcome = try await f.pipeline(summarizer).run(meetingId: id)
        #expect(outcome.warnings[.summarize] != nil)
        #expect(try f.current().title == "要約のあいだに付けた題名" && !f.current().titleAuto)
    }

    @Test("ほかの端末で直した題名を当てると、要約が題名を付ける印が外れる（同じ文字でも）")
    func cloudEditClearsFlag() throws {
        let f = try TitleFixture(title: "要約が付けた題名"); defer { f.cleanup() }
        #expect(try f.store.applyCloudMeetingEdit(meetingId: f.meeting.id, field: CloudEditField.title, value: "要約が付けた題名") == .applied)
        #expect(try f.current().titleAuto == false && f.current().title == "要約が付けた題名")
    }
}
