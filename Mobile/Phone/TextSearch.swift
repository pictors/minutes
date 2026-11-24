import Foundation
import SwiftUI

/// 画面の検索の決まり（一覧の会議の名前・全文の発言）: 空白で区切った語をすべて含むか。
/// 大文字と小文字、全角と半角、ひらがなとカタカナの違いは見ない。
enum TextSearch {
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 比べる前にそろえる
    static func folded(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
        return folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
    }

    static func matches(_ text: String, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = folded(text)
        return terms.allSatisfy { haystack.contains(folded($0)) }
    }

    /// 文の中で語に当たる所。ひらがなとカタカナの違いは、語を両方の書き方にして探す（混ぜて書いた語は、当たっても色が付かないことがある）。
    static func ranges(of terms: [String], in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for term in terms {
            let variants = Set([term, term.applyingTransform(.hiraganaToKatakana, reverse: false), term.applyingTransform(.hiraganaToKatakana, reverse: true)].compactMap { $0 })
            for variant in variants where !variant.isEmpty {
                var start = text.startIndex
                while start < text.endIndex, let range = text.range(of: variant, options: [.caseInsensitive, .widthInsensitive], range: start..<text.endIndex) {
                    result.append(range)
                    start = range.upperBound
                }
            }
        }
        return result
    }

    /// 語に当たる所に色を付けた文
    static func highlighted(_ text: String, terms: [String], tint: Color) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges(of: terms, in: text) {
            guard let converted = Range<AttributedString.Index>(range, in: attributed) else { continue }
            attributed[converted].backgroundColor = tint.opacity(0.28)
            attributed[converted].font = .body.weight(.semibold)
        }
        return attributed
    }
}
