import Foundation

/// ElevenLabs の長い音声で、つなぎ目の発言が 2 回出るのを除く（SPEC §5.3）。
///
/// 見えた形（2026-11-22、架空の 54 分の会議）: ある時点に、そこから先の発言がまとめて時刻の幅 0（`end - start` が 5 ms 未満）で並び、
/// すぐ後ろに同じ発言が正しい時刻でもう一度並ぶ。幅 0 の並びの頭は、後ろの写しから欠けた発言で、ほかにはない。
/// 幅 0 の並びの途中には、幅のある語も少し混じる。長い音声を分けて処理してつなぐところの重なりとみられる。
///
/// 除き方: 幅 0 の語の塊（内容のある語が 5 語以上）を手がかりに、後ろ 120 秒の語と長く同じ並び（文字と数字で 20 字以上、
/// 異なる文字 8 種以上）を探す。見つかったら、同じずれ幅のまま前後に一致を延ばし（数語の食い違いは越える）、
/// 前の写しのうち後ろと重なる部分だけを除く。重ならない頭と、後ろと重ならない幅 0 の語（文末の数語、相づちの連なりなど）は残す。
///
/// 実際の会議では、幅 0 の塊はよく出る（相づちの連なり、時刻の潰れた発言）が、後ろと長く重なるものはなかった（2026-11-22 の確認）。
public enum CollapsedDuplicateFilter {
    /// これより短い語を幅 0 とみなす（秒）。
    public static let zeroWidth = 0.005
    /// 手がかりにする幅 0 の塊の、内容のある語の数の下限。
    public static let minRunWords = 5
    /// 後ろの写しを探す範囲（塊の始まりからの秒）。
    public static let lookahead: Double = 120
    /// 重なりとみなす一致の長さの下限（文字と数字の数）。
    public static let minMatchCharacters = 20
    /// 一致に含まれる異なる文字の数の下限（「うんうん」のような相づちの連なりを重なりとみなさない）。
    public static let minDistinctCharacters = 8
    /// 一致を延ばすとき、越えてよい食い違いの語の数。
    static let maxSkip = 2
    /// 食い違いを越えたあとに続く一致の長さの下限（文字と数字の数）。
    static let minBlockCharacters = 4
    /// 一度に比べる語の数の上限（極端な入力で時間をかけない）。
    static let maxCompareTokens = 4000
    /// 切れ目をずらしてよい語の数（偶然同じになった数語だけをずらす）。
    static let maxCutSlide = 8

    /// 重なる部分を除いた語の列と、除いた語の数（区切りや空白を含む）を返す。
    public static func apply(to words: [TranscriptWord]) -> (words: [TranscriptWord], removed: Int) {
        var words = words
        var keys = words.map { normalizedKey($0.text) }
        // 比べるのは整数で（同じ文字列に同じ番号。区切り・空白は 0）
        var numbering: [String: Int] = ["": 0]
        var ids = keys.map { key in
            if let id = numbering[key] { return id }
            let id = numbering.count
            numbering[key] = id
            return id
        }
        var removed = 0
        var cursor = 0
        while let seed = nextSeed(words: words, ids: ids, from: cursor) {
            if let range = duplicateRange(seed: seed, words: words, keys: keys, ids: ids) {
                words.removeSubrange(range)
                keys.removeSubrange(range)
                ids.removeSubrange(range)
                removed += range.count
                cursor = range.lowerBound
            } else {
                cursor = seed.upperBound
            }
        }
        return (words, removed)
    }

    /// 比べるための形: 互換の正規化と小文字化のうえ、文字と数字だけを残す（区切り・空白は空になる）。
    static func normalizedKey(_ text: String) -> String {
        String(text.precomposedStringWithCompatibilityMapping.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func isZeroWidth(_ word: TranscriptWord) -> Bool {
        word.end - word.start < zeroWidth
    }

    /// `from` 以降で最初の、幅 0 の語が続く塊（内容のある語が `minRunWords` 以上）。
    static func nextSeed(words: [TranscriptWord], ids: [Int], from start: Int) -> Range<Int>? {
        var index = start
        while index < words.count {
            guard isZeroWidth(words[index]) else {
                index += 1
                continue
            }
            var end = index
            var content = 0
            while end < words.count, isZeroWidth(words[end]) {
                if ids[end] != 0 { content += 1 }
                end += 1
            }
            if content >= minRunWords { return index..<end }
            index = end
        }
        return nil
    }

    /// 塊 `seed` を手がかりに、前の写しのうち後ろと重なる語の範囲を返す。重なりがなければ nil。
    static func duplicateRange(seed: Range<Int>, words: [TranscriptWord], keys: [String], ids: [Int]) -> Range<Int>? {
        // 内容のある語だけを並べた列（tokens[i] は words の添字）
        let tokens = ids.indices.filter { ids[$0] != 0 }
        func key(_ position: Int) -> String { keys[tokens[position]] }
        func id(_ position: Int) -> Int { ids[tokens[position]] }
        func characters(_ positions: Range<Int>) -> Int { positions.reduce(0) { $0 + key($1).count } }

        guard let seedStart = tokens.firstIndex(where: { $0 >= seed.lowerBound }), tokens[seedStart] < seed.upperBound else { return nil }
        let seedEnd = min(tokens.firstIndex(where: { $0 >= seed.upperBound }) ?? tokens.count, seedStart + maxCompareTokens)
        let limitTime = words[seed.lowerBound].start + lookahead
        var windowEnd = seedEnd
        while windowEnd < tokens.count, windowEnd - seedEnd < maxCompareTokens, words[tokens[windowEnd]].start <= limitTime {
            windowEnd += 1
        }
        guard windowEnd > seedEnd else { return nil }

        // 塊と後ろの最長の一致（文字数で比べる）
        guard let anchor = longestCommonRun(seedStart..<seedEnd, seedEnd..<windowEnd, id: id, characters: { key($0).count }) else { return nil }
        let anchorText = (anchor.a..<(anchor.a + anchor.length)).map(key).joined()
        guard anchorText.count >= minMatchCharacters, Set(anchorText).count >= minDistinctCharacters else { return nil }
        let shift = anchor.b - anchor.a

        // 同じずれ幅のまま、前（塊の始まりまで）と後ろ（後ろの写しの始まりまで）へ延ばす
        let matches = { (position: Int) -> Bool in id(position) == id(position + shift) }
        let lower = extend(from: anchor.a - 1, step: -1, bound: seedStart, matches: matches, characters: { key($0).count })
        let upperBound = min(lower + shift, tokens.count - shift)
        let extended = extend(from: anchor.a + anchor.length, step: 1, bound: upperBound - 1, matches: matches, characters: { key($0).count })
        let upper = min(extended, upperBound)
        guard lower < upper else { return nil }
        let blob = lower..<upper

        // 前の写しは主に幅 0、後ろの写しは主に正しい時刻であること
        let zeroInBlob = blob.filter { isZeroWidth(words[tokens[$0]]) }.count
        let zeroInCopy = blob.filter { isZeroWidth(words[tokens[$0 + shift]]) }.count
        guard zeroInBlob * 2 >= blob.count, zeroInCopy * 2 <= blob.count, characters(blob) >= minMatchCharacters else { return nil }

        // 切れ目: 一致の頭の数語は、偶然同じ文字（頭の文末の「ます」と、前の写しの文末の「ます」など）のことがある。
        // 同じ文字が並ぶあいだは切れ目をずらせるので、時刻の跳びがいちばん大きいところを後ろの写しの始まりとみなし、その手前は残す。
        var cut = 0
        var bestGap = -Double.infinity
        var offset = 0
        while lower + offset < upper, offset <= maxCutSlide {
            let copyStart = lower + shift + offset
            guard copyStart < tokens.count else { break }
            let gap = words[tokens[copyStart]].start - words[tokens[copyStart - 1]].end
            if gap > bestGap {
                bestGap = gap
                cut = offset
            }
            guard matches(lower + offset) else { break }
            offset += 1
        }
        if upper == lower + shift {
            // 前の写しが後ろの写しまで続く。あいだの区切り・空白ごと除く
            return tokens[lower + cut]..<tokens[lower + shift + cut]
        }
        // 食い違い（語の抜けや足し）で一致が途切れた。重なった部分と、その直後の区切り・空白だけを除き、途切れた先は残す
        // （途切れた先に幅 0 の塊が続けば、次の手がかりとして改めて調べる）
        var end = tokens[upper - 1] + 1
        while end < ids.count, ids[end] == 0 { end += 1 }
        return tokens[lower + cut]..<end
    }

    /// 2 つの範囲の最長の共通の並び（語の一致、長さは文字数で比べる）。
    static func longestCommonRun(_ a: Range<Int>, _ b: Range<Int>, id: (Int) -> Int, characters: (Int) -> Int) -> (a: Int, b: Int, length: Int)? {
        let aKeys = a.map(id)
        let bKeys = b.map(id)
        let aCharacters = a.map(characters)
        guard !aKeys.isEmpty, !bKeys.isEmpty else { return nil }
        var previous = [Int](repeating: 0, count: bKeys.count + 1)
        var previousChars = [Int](repeating: 0, count: bKeys.count + 1)
        var current = previous
        var currentChars = previousChars
        var best: (a: Int, b: Int, length: Int, chars: Int)?
        for i in 1...aKeys.count {
            for j in 1...bKeys.count {
                if aKeys[i - 1] == bKeys[j - 1] {
                    current[j] = previous[j - 1] + 1
                    currentChars[j] = previousChars[j - 1] + aCharacters[i - 1]
                    if currentChars[j] > (best?.chars ?? 0) {
                        best = (a.lowerBound + i - current[j], b.lowerBound + j - current[j], current[j], currentChars[j])
                    }
                } else {
                    current[j] = 0
                    currentChars[j] = 0
                }
            }
            swap(&previous, &current)
            swap(&previousChars, &currentChars)
        }
        return best.map { ($0.a, $0.b, $0.length) }
    }

    /// `start` から `step` の向きに一致を延ばし、受け入れた端を返す（前へなら新しい始まり、後ろへなら新しい終わり（含まない））。
    /// 食い違いは `maxSkip` 語まで越え、その先に `minBlockCharacters` 字以上の一致が続くか、一致が端まで続くときだけ受け入れる。
    static func extend(from start: Int, step: Int, bound: Int, matches: (Int) -> Bool, characters: (Int) -> Int) -> Int {
        func inside(_ position: Int) -> Bool { step > 0 ? position <= bound : position >= bound }
        var accepted = start - step
        var position = start
        while inside(position) {
            var skipped = 0
            while inside(position), !matches(position), skipped < maxSkip {
                position += step
                skipped += 1
            }
            var blockCharacters = 0
            var blockEnd = position
            while inside(blockEnd), matches(blockEnd) {
                blockCharacters += characters(blockEnd)
                blockEnd += step
            }
            if blockEnd == position || (skipped > 0 && blockCharacters < minBlockCharacters && inside(blockEnd)) { break }
            accepted = blockEnd - step
            position = blockEnd
        }
        return step > 0 ? accepted + 1 : accepted
    }
}
