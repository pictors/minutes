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

    /// system は会議の言語と要約の言語を差し込む（日本語の会議は v2 と同じ文になる）。
    public func systemMessage(for input: SummaryInput) -> String {
        fill(system, input: input, extra: [:])
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
            .replacingOccurrences(of: "{{meeting_language}}", with: (input.meetingLanguage ?? .ja).title)
            .replacingOccurrences(of: "{{output_language}}", with: Self.outputLanguageText(input.outputLanguage ?? .ja))
        for (key, value) in extra { text = text.replacingOccurrences(of: key, with: value) }
        return text
    }

    /// 「出力はすべて{{output_language}}。」に入れる言葉。英語は本文の欄を明示する（指示文が日本語なので、つられて日本語で書かせない）。
    static func outputLanguageText(_ language: MeetingLanguage) -> String {
        switch language {
        case .ja: "日本語"
        case .en: "英語（summary_md・decisions・action_items・open_questions の文章を英語で書く）"
        }
    }
}
