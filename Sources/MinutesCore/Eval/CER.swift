import Foundation

/// 文字誤り率（CER）: NFKC 正規化・空白と記号除去後の編集距離 / 参照文字数（SPEC §12 Phase 0）。
public struct CERResult: Sendable, Equatable {
    public var referenceLength: Int
    public var hypothesisLength: Int
    public var editDistance: Int
    public var cer: Double {
        referenceLength == 0 ? (hypothesisLength == 0 ? 0 : 1) : Double(editDistance) / Double(referenceLength)
    }
}

public enum TextNormalizer {
    /// NFKC 正規化 → 小文字化 → 空白・句読点・記号を除去した Unicode スカラー列。
    public static func normalizeForCER(_ text: String) -> [Unicode.Scalar] {
        let nfkc = text.precomposedStringWithCompatibilityMapping.lowercased()
        var removal = CharacterSet.whitespacesAndNewlines
        removal.formUnion(.punctuationCharacters)
        removal.formUnion(.symbols)
        removal.formUnion(.controlCharacters)
        // 日本語の中黒・長音記号は語の一部として残す（「メール・アドレス」「サーバー」）。
        let keep = CharacterSet(charactersIn: "・ー〜")
        return nfkc.unicodeScalars.filter { !removal.contains($0) || keep.contains($0) }
    }

    /// 行頭の話者プレフィックス（"田中: " / "Speaker 1：" など）を除去する。
    public static func stripSpeakerPrefixes(_ text: String) -> String {
        let pattern = #"(?m)^\s*[^\s:：\[\]]{1,20}\s*[:：]\s*"#
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    /// "[00:12:30]" 形式のタイムスタンプを除去する。
    public static func stripTimestamps(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[\d{1,2}:\d{2}(:\d{2})?(\.\d+)?\]"#, with: "", options: .regularExpression)
    }
}

public enum EditDistance {
    /// Levenshtein 距離（挿入・削除・置換 = 1）。2 行 DP。
    public static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        // 短い方を列に取ってメモリを節約する
        let (rows, cols) = a.count >= b.count ? (a, b) : (b, a)
        var previous = Array(0...cols.count)
        var current = [Int](repeating: 0, count: cols.count + 1)
        for i in 1...rows.count {
            current[0] = i
            let rowValue = rows[i - 1]
            for j in 1...cols.count {
                let cost = rowValue == cols[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[cols.count]
    }
}

public enum CER {
    public static func compute(reference: String, hypothesis: String) -> CERResult {
        let ref = TextNormalizer.normalizeForCER(reference)
        let hyp = TextNormalizer.normalizeForCER(hypothesis)
        let distance = EditDistance.levenshtein(ref, hyp)
        return CERResult(referenceLength: ref.count, hypothesisLength: hyp.count, editDistance: distance)
    }
}
