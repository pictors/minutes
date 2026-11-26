import Foundation

/// 要約が付ける題名（題名を付けずに録った会議。SPEC §8.1）。
/// モデルの出力をそのまま題名にしない: 1 行にし、飾り（引用符・見出しの記号・文末の句点）を外し、長さを切る。
/// サーバー（非公開）の iPhone・Watch の会議の題名付けと同じ決まりで、例の表
/// `Tests/MinutesCoreTests/Fixtures/summary-title-cases.json` をサーバーのテストにも写す。変えるときは両方をそろえる。
public enum SummaryTitle {
    /// 付ける題名の長さの上限（文字。一覧で 1 行に収まるくらい）。
    public static let maxLength = 60

    /// 題名のない会議を要約に渡すときの題名（要約の入力。付けた題名に替わっても入力は変えない）。
    public static let untitledForPrompt = "（題名なし）"

    /// JSON Schema の `title` の説明（指示文の代わりに、ここで頼む）。
    public static let schemaDescription = "会議の題名。一覧でほかの会議と見分けられるよう、話し合った中身を表す短い名詞句にする（日本語なら 30 字まで、英語なら 8 語まで。例「新プランの価格改定の相談」「Pricing review for the new plan」）。summary_md と同じ言語で書く。日付・時刻、「会議」「打ち合わせ」だけの名前、引用符、文末の句点は付けない。発言が少なく中身が分からないときは空文字にする"

    /// 題名にしない名前（題名がないことを言っているだけのもの）。
    static let placeholders: Set<String> = ["題名なし", "無題", "無題の会議", "会議", "打ち合わせ", "ミーティング", "untitled", "untitled meeting", "meeting", "no title", "n/a"]

    static let quotePairs: [(open: String, close: String)] = [
        ("「", "」"), ("『", "』"), ("“", "”"), ("\"", "\""), ("'", "'"), ("（", "）"), ("(", ")"), ("**", "**"), ("`", "`"),
    ]

    /// 題名として使える形にする。使えなければ nil。
    public static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // 最初の中身のある行だけ（制御文字は空白に）
        let lines = raw.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        var text = lines.lazy.map { line -> String in
            String(String.UnicodeScalarView(line.unicodeScalars.map { scalar in
                scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x2028 || scalar.value == 0x2029 ? " " : scalar
            })).trimmingCharacters(in: .whitespaces)
        }.first { !$0.isEmpty } ?? ""
        text = text.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^[-*・]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // 文末の句点と、全体を囲む引用符・かっこを外す（中に同じ記号があるときは囲みとみなさない）。外すものがなくなるまで繰り返す
        var changed = true
        while changed {
            changed = false
            let trimmed = text.replacingOccurrences(of: #"[。．.]+$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if trimmed != text {
                text = trimmed
                changed = true
            }
            for pair in quotePairs {
                guard text.count >= pair.open.count + pair.close.count, text.hasPrefix(pair.open), text.hasSuffix(pair.close) else { continue }
                let inner = String(text.dropFirst(pair.open.count).dropLast(pair.close.count))
                if inner.contains(pair.open) || inner.contains(pair.close) { continue }
                text = inner.trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        guard !text.isEmpty, !placeholders.contains(text.lowercased()) else { return nil }
        let scalars = Array(text.unicodeScalars)
        if scalars.count > maxLength {
            text = String(String.UnicodeScalarView(scalars.prefix(maxLength))).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}

/// 要約と、頼んだときだけ付く題名（整えたあと。付けられなければ nil）。
public struct SummaryOutput: Sendable, Equatable {
    public var summary: MinutesSummary
    public var title: String?

    public init(summary: MinutesSummary, title: String? = nil) {
        self.summary = summary
        self.title = title
    }
}

/// 題名も頼んだときのモデルの出力を読む（要約の欄と `title`）。題名は整えてから返す。
public struct TitledSummary: Decodable, Sendable {
    public var summary: MinutesSummary
    public var title: String?

    private enum CodingKeys: String, CodingKey { case title }

    public init(from decoder: any Decoder) throws {
        summary = try MinutesSummary(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = SummaryTitle.clean((try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil)
    }

    public var output: SummaryOutput { SummaryOutput(summary: summary, title: title) }
}
