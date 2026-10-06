import Foundation
import MinutesCore
import Testing

@Suite("Session 状態機械")
struct SessionStateMachineTests {
    @Test("SPEC §6.3 の遷移")
    func transitions() throws {
        var machine = SessionStateMachine()
        #expect(machine.state == .idle)
        try machine.handle(.armConditionMet)
        #expect(machine.state == .armed)
        try machine.handle(.audioDetected)
        #expect(machine.state == .recording)
        try machine.handle(.silenceTimeout)
        #expect(machine.state == .finalizing)
        try machine.handle(.audioResumed)
        #expect(machine.state == .recording)
        try machine.handle(.manualStop)
        #expect(machine.state == .finalizing)
        try machine.handle(.pipelineFailed("boom"))
        #expect(machine.state == .failed)
        try machine.handle(.retryPipeline)
        #expect(machine.state == .finalizing)
        try machine.handle(.pipelineSucceeded)
        #expect(machine.state == .done)
        try machine.handle(.reset)
        #expect(machine.state == .idle)
    }

    @Test("無効な遷移はエラー")
    func invalid() {
        var machine = SessionStateMachine()
        #expect(throws: SessionTransitionError.self) { try machine.handle(.audioDetected) }
        #expect(throws: SessionTransitionError.self) { try machine.handle(.pipelineSucceeded) }
        #expect(SessionStateMachine.next(from: .done, on: .manualStart) == nil)
        #expect(SessionStateMachine.next(from: .armed, on: .targetProcessExited) == .idle)
        #expect(SessionStateMachine.next(from: .idle, on: .manualStart) == .recording)
    }
}

@Suite("Summarizer（Claude tool use のパース）")
struct SummarizerTests {
    @Test("record_minutes の tool_use を MinutesSummary に変換する（golden）")
    func parse() throws {
        let url = try #require(Bundle.module.url(forResource: "claude_record_minutes", withExtension: "json", subdirectory: "Fixtures"))
        let summary = try ClaudeSummarizer.parseResponse(try Data(contentsOf: url))
        #expect(summary.decisions.count == 1)
        #expect(summary.decisions[0].evidence == [5, 6])
        #expect(summary.actionItems.map(\.kind) == [.ownCommitment, .theirTask, .delegable])
        #expect(summary.actionItems[0].due == "2026-09-24")
        #expect(summary.actionItems[1].due == nil)
        #expect(summary.keytermsLearned == ["Nimbus", "サポート窓口"])
        let remapped = summary.remappingEvidence([5: 105, 6: 106, 8: 108])
        #expect(remapped.decisions[0].evidence == [105, 106])
        #expect(remapped.actionItems[1].evidence.isEmpty)
    }

    @Test("refusal / max_tokens / tool_use なしはエラー")
    func errors() {
        #expect(throws: SummarizerError.self) {
            _ = try ClaudeSummarizer.parseResponse(Data(#"{"stop_reason":"refusal","stop_details":{"type":"refusal","explanation":"no"},"content":[]}"#.utf8))
        }
        #expect(throws: SummarizerError.truncated) {
            _ = try ClaudeSummarizer.parseResponse(Data(#"{"stop_reason":"max_tokens","content":[]}"#.utf8))
        }
        #expect(throws: SummarizerError.self) {
            _ = try ClaudeSummarizer.parseResponse(Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"hi"}]}"#.utf8))
        }
    }

    @Test("ツール定義は strict 用に additionalProperties=false と required を持つ")
    func toolSchema() throws {
        let tool = ClaudeSummarizer.recordMinutesTool
        #expect(tool["name"] as? String == "record_minutes")
        #expect(tool["strict"] as? Bool == true)
        let schema = try #require(tool["input_schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        let required = try #require(schema["required"] as? [String])
        #expect(Set(required) == ["summary_md", "decisions", "action_items", "open_questions", "keyterms_learned"])
        _ = try JSONSerialization.data(withJSONObject: tool)
    }

    @Test("プロンプトのパースと差し込み")
    func prompt() throws {
        let prompt = try SummaryPrompt.loadBundled()
        #expect(prompt.version >= 1)
        #expect(prompt.system.contains("JSON Schema"))
        let input = SummaryInput(meetingTitle: "定例", startedAt: Date(timeIntervalSince1970: 1_800_000_000), attendees: [Attendee(name: "田中", email: "t@example.com")], segments: [
            .init(id: 1, track: "system", tStart: 0, tEnd: 2, speaker: "spk_0", text: "おはようございます"),
        ], speakerNames: ["spk_0": "田中"])
        let text = input.transcriptText()
        #expect(text == "[seg 1][00:00:00] 田中: おはようございます")
    }
}
