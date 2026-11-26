import Foundation

/// 構造化出力を返すローカル CLI のプロバイダ（Codex / Claude Code）に共通の手順。
/// 長い会議は分割して部分要約 → 統合し、各応答の根拠 ID を確かめる。
enum StructuredSummary {
    /// generate: ユーザーメッセージと、その応答で根拠に使える segment id を受け取って要約を返す。
    /// titled: 題名も頼む（SPEC §8.1）。分けたときは、統合の依頼だけで頼む（部分要約には頼まない）。
    static func summarize(_ input: SummaryInput, prompt: SummaryPrompt, titled: Bool = false, generate: (_ user: String, _ validIds: Set<Int>, _ titled: Bool) async throws -> SummaryOutput) async throws -> SummaryOutput {
        guard !input.segments.isEmpty else { return SummaryOutput(summary: .empty) }
        let parts = parts(input)
        if parts.count == 1 {
            return try await generate(prompt.userMessage(for: input, transcript: input.transcriptText(), partLabel: nil), Set(input.segments.map(\.id)), titled)
        }
        var partials: [MinutesSummary] = []
        for (index, segments) in parts.enumerated() {
            try Task.checkCancellation()
            var part = input
            part.segments = segments
            partials.append(try await generate(prompt.userMessage(for: part, transcript: part.transcriptText(), partLabel: "パート \(index + 1)/\(parts.count)"), Set(segments.map(\.id)), false).summary)
        }
        let json = String(decoding: try JSONCoding.encoder().encode(partials), as: UTF8.self)
        return try await generate(prompt.mergeMessage(for: input, partialSummaries: json), Set(input.segments.map(\.id)), titled)
    }

    /// JSON Schema だけでは保証できない、根拠 ID の実在を確認する。
    static func isValid(_ summary: MinutesSummary, validIds: Set<Int>) -> Bool {
        let evidence = summary.decisions.map(\.evidence) + summary.actionItems.map(\.evidence) + summary.openQuestions.map(\.evidence)
        return !summary.summaryMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && evidence.allSatisfy { !$0.isEmpty && Set($0).isSubset(of: validIds) }
    }

    static func parts(_ input: SummaryInput) -> [[TranscriptDocument.Segment]] {
        var parts: [[TranscriptDocument.Segment]] = []
        var current: [TranscriptDocument.Segment] = []
        var characters = 0
        for segment in input.segments {
            let timeLimit = input.durationSeconds > 90 * 60 && segment.tStart - (current.first?.tStart ?? segment.tStart) >= 45 * 60
            if !current.isEmpty, timeLimit || characters + segment.text.count > 50_000 {
                parts.append(current)
                current = []
                characters = 0
            }
            current.append(segment)
            characters += segment.text.count
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
