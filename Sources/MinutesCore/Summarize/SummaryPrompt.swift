import Foundation

/// `Resources/Prompts/summarize_ja.md` を読む。先頭行の `<!-- version: N -->` をバージョンとして notes.model に記録する。
public struct SummaryPrompt: Sendable {
    public static let resourceName = "summarize_ja"
    public var version: Int
    public var system: String
    public var userTemplate: String
    public var mergeTemplate: String

    public var fingerprint: String {
        PipelineFingerprint.hash(Data("\(version)\n\(system)\n\(userTemplate)\n\(mergeTemplate)".utf8))
    }

    public static func loadBundled() throws -> SummaryPrompt {
        guard let url = CoreResources.url(forResource: SummaryPrompt.resourceName, withExtension: "md", subdirectory: "Resources/Prompts") else {
            throw SummarizerError.invalidResponse("プロンプト \(SummaryPrompt.resourceName).md が見つかりません")
        }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// セクション区切り `## system` / `## user` / `## merge` で分割する。
    public static func parse(_ text: String) throws -> SummaryPrompt {
        var version = 1
        if let match = text.range(of: #"<!--\s*version:\s*(\d+)\s*-->"#, options: .regularExpression) {
            let digits = text[match].filter(\.isNumber)
            version = Int(digits) ?? 1
        }
        var sections: [String: String] = [:]
        var currentName: String?
        var buffer: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if let currentName { sections[currentName] = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
                currentName = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                buffer = []
            } else if currentName != nil {
                buffer.append(line)
            }
        }
        if let currentName { sections[currentName] = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let system = sections["system"], let user = sections["user"], let merge = sections["merge"] else {
            throw SummarizerError.invalidResponse("プロンプトに system / user / merge セクションが必要です")
        }
        return SummaryPrompt(version: version, system: system, userTemplate: user, mergeTemplate: merge)
    }

    func userMessage(for input: SummaryInput, transcript: String, partLabel: String?) -> String {
        fill(userTemplate, input: input, extra: [
            "{{transcript}}": transcript,
            "{{part_label}}": partLabel ?? "（全体）",
        ])
    }

    func mergeMessage(for input: SummaryInput, partialSummaries: String) -> String {
        fill(mergeTemplate, input: input, extra: ["{{partial_summaries}}": partialSummaries])
    }

    private func fill(_ template: String, input: SummaryInput, extra: [String: String]) -> String {
        let attendees = input.attendees.isEmpty ? "（不明）" : input.attendees.map { $0.email.map { "\($0.self)" } != nil ? "\($0.name) <\($0.email!)>" : $0.name }.joined(separator: ", ")
        var text = template
            .replacingOccurrences(of: "{{title}}", with: input.meetingTitle)
            .replacingOccurrences(of: "{{date}}", with: input.startedAt.map { JSONCoding.iso8601Local($0) } ?? "不明")
            .replacingOccurrences(of: "{{attendees}}", with: attendees)
            .replacingOccurrences(of: "{{previous_summary}}", with: input.previousSummaryMd ?? "（なし）")
        for (key, value) in extra { text = text.replacingOccurrences(of: key, with: value) }
        return text
    }
}
