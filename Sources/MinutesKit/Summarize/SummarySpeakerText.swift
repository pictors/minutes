import Foundation

/// 要約の文と担当の中の話者を、見せる形にする（Mac と iPhone の表示。SPEC §5.7）。
///
/// 要約は、名前のない話者をラベル（spk_0 など）のまま書く。iPhone・Watch の 1 トラックの会議ではほとんど毎回出る
/// （2026-11-25 に本物の Opus 5.5 で確かめた。「spk_1 の提案により、リリースは来週金曜日に決定」）。
/// 保存した要約は変えず、表示するときだけ替えるので、あとで話者の名前を付けても直しても、要約し直さずに出る。
///
/// 決まりはサーバー（非公開）の共有のページと同じにする。
/// 同じ例の表（`Tests/MinutesCoreTests/Fixtures/summary-speaker-text-cases.json`）をサーバーのテストにも写す。変えるときは両方をそろえる。
public enum SummarySpeakerText {
    /// 文の中の `spk_` + 数字を `name(ラベル)` に替える。
    /// - ラベルの前後が ASCII の英数字と `_` でないときだけ替える（JavaScript の `\b` と同じ見方で、サーバーと同じ。「下書きはspk_2、」も替える。
    ///   Swift の正規表現の `\b` は Unicode の語の境目なので、かなと英字のあいだで境目にならず、使わない）。
    /// - ラベルの前後の空白 1 つは、替えたあと両側がかな・漢字・全角なら外す（「spk_0 が」→「山田が」）。英字の名前や英語の文では残す。
    public static func replacingLabels(in text: String, name: (String) -> String) -> String {
        guard text.contains("spk_") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard let match = labelMatch(in: scalars, at: index) else {
                out.append(scalars[index])
                index += 1
                continue
            }
            let label = String(String.UnicodeScalarView(scalars[match.labelStart..<match.labelEnd]))
            let shown = name(label)
            let previous = match.start > 0 ? scalars[match.start - 1] : nil
            let next = match.end < scalars.count ? scalars[match.end] : nil
            let keepBefore = match.spaceBefore && !(isWide(previous) && isWide(shown.unicodeScalars.first))
            let keepAfter = match.spaceAfter && !(isWide(shown.unicodeScalars.last) && isWide(next))
            if keepBefore { out.append(" ") }
            out.append(contentsOf: shown.unicodeScalars)
            if keepAfter { out.append(" ") }
            index = match.end
        }
        return String(out)
    }

    /// `spk_N` の N（spk_2 → 2）。その形でなければ nil。
    public static func labelNumber(_ label: String) -> Int? {
        guard label.hasPrefix("spk_") else { return nil }
        let digits = label.dropFirst(4)
        guard !digits.isEmpty, digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(digits)
    }

    /// やることの担当「me」を、自分（録った人）として出すか。
    /// 「me」は自分のマイクの話者（Mac の 2 トラック）。iPhone・Watch の 1 トラックの会議には「me」の話者がいないので、
    /// 要約が書いた「me」は推し量りで、自分とは限らない。手で足したやること（`manual`。既定の担当は「me」）は、利用者が自分で書いたもの。
    /// - Parameter meetingHasSelfSpeaker: その会議の文字起こしに「me」の話者がいるか。分からない（まだ読んでいない）ときは nil で、自分として出す。
    public static func ownerIsSelf(_ action: MinutesSummary.ActionItem, meetingHasSelfSpeaker: Bool?) -> Bool {
        guard action.owner == "me" else { return false }
        return meetingHasSelfSpeaker != false || action.manual == true
    }

    // MARK: - 見つけ方

    private struct LabelMatch {
        /// 前の空白を含めた頭
        var start: Int
        var labelStart: Int
        var labelEnd: Int
        /// 後ろの空白を含めた終わり（この位置は含まない）
        var end: Int
        var spaceBefore: Bool
        var spaceAfter: Bool
    }

    /// `( ?)\b(spk_\d+)\b( ?)`（JavaScript の意味）を `index` から当てる。
    private static func labelMatch(in scalars: [Unicode.Scalar], at index: Int) -> LabelMatch? {
        let spaceBefore = scalars[index] == " "
        let labelStart = spaceBefore ? index + 1 : index
        if !spaceBefore, index > 0, isWordCharacter(scalars[index - 1]) { return nil }
        guard let labelEnd = labelEnd(in: scalars, from: labelStart) else { return nil }
        let spaceAfter = labelEnd < scalars.count && scalars[labelEnd] == " "
        return LabelMatch(start: index, labelStart: labelStart, labelEnd: labelEnd, end: spaceAfter ? labelEnd + 1 : labelEnd,
                          spaceBefore: spaceBefore, spaceAfter: spaceAfter)
    }

    /// `from` から `spk_` + 数字 1 つ以上が続き、そのあとが英数字と `_` でなければ、数字の終わりの位置を返す。
    private static func labelEnd(in scalars: [Unicode.Scalar], from start: Int) -> Int? {
        let prefix: [Unicode.Scalar] = ["s", "p", "k", "_"]
        guard start + prefix.count < scalars.count, Array(scalars[start..<start + prefix.count]) == prefix else { return nil }
        var end = start + prefix.count
        while end < scalars.count, ("0"..."9").contains(scalars[end]) { end += 1 }
        guard end > start + prefix.count else { return nil }
        if end < scalars.count, isWordCharacter(scalars[end]) { return nil }
        return end
    }

    /// JavaScript の `\w`（ASCII の英数字と `_`）
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
    }

    /// かな・漢字・全角の文字（サーバーと同じ範囲）
    private static func isWide(_ scalar: Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        return (0x3000...0x30FF).contains(value) || (0x3400...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) || (0xFF00...0xFFEF).contains(value)
    }
}
