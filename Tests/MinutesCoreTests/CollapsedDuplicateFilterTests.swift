import Foundation
import MinutesCore
import Testing

/// ElevenLabs の長い音声のつなぎ目で、時刻の潰れた（幅 0 の）発言がすぐ後ろと重なるのを除く（SPEC §5.3）。会議と人名は架空。
@Suite("ElevenLabs: つなぎ目の重複を除く")
struct CollapsedDuplicateFilterTests {
    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// 1 文字ずつの語（日本語の応答の形）。`step` が 0 なら幅 0 で `start` に並べる。句点は幅 0。
    func characters(_ text: String, from start: Double, step: Double, speaker: String = "speaker_0") -> [TranscriptWord] {
        var time = start
        return text.map { character in
            if "。、".contains(character) {
                return TranscriptWord(text: String(character), start: time, end: time, speakerLabel: speaker)
            }
            let word = TranscriptWord(text: String(character), start: time, end: time + step, speakerLabel: speaker)
            time += step
            return word
        }
    }

    func text(_ words: [TranscriptWord]) -> String { words.map(\.text).joined() }

    func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test("架空の 54 分の会議のつなぎ目: 潰れた写しのうち後ろと重なる部分だけを除き、後ろの写しから欠けた頭は残す")
    func goldenSeam() throws {
        let response = try ElevenLabsTranscriber.parseResponse(fixture("elevenlabs_collapsed_seam"))
        #expect(response.words.count == 493)
        let result = ElevenLabsTranscriber.makeResult(from: response, meta: ["provider": "test"])
        #expect(result.providerMeta["collapsed_duplicate_words_removed"] == "204")
        #expect(result.providerMeta["provider"] == "test")

        let segments = result.segments.map { "\($0.speakerLabel ?? "-") \($0.text)" }
        #expect(segments == [
            "speaker_3 名古屋の倉庫の鍵の受け渡しは来月の初めで大丈夫でしょうか。",
            "speaker_0 ありがとうございます。赤染は週明けにもう一度見ます。続いて、光の価格表の件に移ります。加藤さん、お願いします。",
            "speaker_3 調査の結果は八割ほどできています。残りは今週中までに仕上げます。",
            "speaker_3 法務の藤田さんから表示が遅いので見てほしいと言われています。",
            "speaker_0 星野観光さんへの説明は明後日の夕方までに必要ですか。",
            "speaker_1 落ち着いて確認します。広洋電機さんには来月の初めに連絡します。ところで、週明けの打ち合わせのコーヒーは加藤さんが手配してくれるそうです。",
            "speaker_1 念のため、渡辺さんにも伝えておきます。",
            "speaker_0 ありがとうございます。光は今週中にもう一度見ます。",
        ])
        // 残った写しは正しい時刻のもの
        #expect(result.segments[2].start == 3194.1)
        #expect(result.segments.last?.end == 3226.64)
        // 潰れた時刻の語は、後ろの写しから欠けた頭（3184.52〜3185.24 秒）のほかに残らない
        let words = try #require(result.words)
        #expect(words.allSatisfy { $0.start < 3185.25 || $0.start > 3194 })
    }

    @Test("後ろの写しまで続く重なりを、数語の食い違いと幅のある語を越えて除く")
    func removesAcrossMismatchAndTimedWords() {
        let head = characters("では次の議題に移ります。", from: 100, step: 0)
        // 潰れた写し: 途中の数語だけ幅がある（応答で見えた形）
        let collapsedA = characters("見積もりの金額は先週のものから変わっていません。", from: 100, step: 0)
        let collapsedB = characters("納品は月末で", from: 100.2, step: 0.05)
        let collapsedC = characters("大丈夫です。", from: 100.5, step: 0)
        // 正しい時刻の写し（1 語だけ違う）
        let copy = characters("見積もりの金額は先週のものから変わっていません。納品は月末で犬丈夫です。", from: 110, step: 0.2, speaker: "speaker_1")
        let tail = characters("承知しました。", from: 130, step: 0.2)
        let words = head + collapsedA + collapsedB + collapsedC + copy + tail

        let result = CollapsedDuplicateFilter.apply(to: words)
        #expect(text(result.words) == "では次の議題に移ります。見積もりの金額は先週のものから変わっていません。納品は月末で犬丈夫です。承知しました。")
        #expect(result.words.filter { $0.text == "見" }.allSatisfy { $0.start >= 110 })
        #expect(result.removed == collapsedA.count + collapsedB.count + collapsedC.count)
    }

    @Test("後ろの写しに語が足されて一致が途切れても、後ろの写しから欠けた頭（文末が偶然同じ）は削らない")
    func keepsHeadWhenCopyHasInsertedWords() {
        let head = characters("では次の議題に移ります。", from: 100, step: 0)
        let collapsedA = characters("見積もりの金額は先週のものから変わっていません。", from: 100, step: 0)
        // 潰れた写しの続き（幅はあるが時刻は潰れたまま）。文末が頭と同じ「ます」
        let collapsedB = characters("納品は月末でお願いします。", from: 100.2, step: 0.05)
        // 正しい時刻の写しには、途中に語が足されている
        let copy = characters("見積もりの金額は先週のものから変わっていません。それと納品は月末でお願いします。", from: 110, step: 0.2, speaker: "speaker_1")
        let tail = characters("承知しました。", from: 130, step: 0.2)

        let result = CollapsedDuplicateFilter.apply(to: head + collapsedA + collapsedB + copy + tail)
        let joined = text(result.words)
        #expect(joined.hasPrefix("では次の議題に移ります。"))
        #expect(!joined.contains("。。"))
        #expect(occurrences(of: "見積もりの金額は先週のものから変わっていません", in: joined) == 1)
        #expect(result.words.filter { $0.text == "見" }.allSatisfy { $0.start >= 110 })
        // 一致が途切れた先の写し（幅のある語）は残る
        #expect(joined == "では次の議題に移ります。納品は月末でお願いします。見積もりの金額は先週のものから変わっていません。それと納品は月末でお願いします。承知しました。")
    }

    @Test("後ろと重ならない幅 0 の語は残す: 末尾の数語、時刻の潰れた別の発言")
    func keepsUnmatchedZeroWidthWords() {
        // 末尾の数語だけ幅 0（say の 60 分で見えた形）
        let ending = characters("本日はありがとうございました", from: 50, step: 0.1) + characters("また来週です。", from: 51.5, step: 0)
        #expect(CollapsedDuplicateFilter.apply(to: ending).removed == 0)

        // 時刻が潰れた発言のあと、別の発言が続く（実際の会議でよく出る形）
        let collapsed = characters("資料の三ページ目の表を見てください。", from: 200, step: 0)
        let next = characters("売上の推移は前の四半期と同じ傾向です。表の三ページ目の数字も同じです。", from: 230, step: 0.15, speaker: "speaker_1")
        #expect(CollapsedDuplicateFilter.apply(to: collapsed + next).removed == 0)
    }

    @Test("相づちの連なりは、後ろに同じ相づちが続いても重なりとみなさない")
    func keepsBackchannels() {
        let filler = "うんうんうんうんはいうんうんうんうんうんうんはいうんうんうんうん"
        let words = characters(filler, from: 300, step: 0)
            + characters(filler, from: 302, step: 0.1, speaker: "speaker_1")
            + characters(filler, from: 310, step: 0)
        #expect(CollapsedDuplicateFilter.apply(to: words).removed == 0)
    }

    @Test("正しい時刻で同じ文を 2 回言ったときは残す（幅 0 の塊がない）")
    func keepsRepeatedSpeech() {
        let sentence = "このボタンを押すと設定の画面が開きます。"
        let words = characters(sentence, from: 0, step: 0.1) + characters(sentence, from: 5, step: 0.1, speaker: "speaker_1")
        #expect(CollapsedDuplicateFilter.apply(to: words).removed == 0)
    }

    @Test("英語の応答（語ごと、空白の語を含む）でも重なりを除く")
    func english() {
        func english(_ sentence: String, from start: Double, step: Double) -> [TranscriptWord] {
            var words: [TranscriptWord] = []
            var time = start
            for (index, token) in sentence.split(separator: " ").enumerated() {
                if index > 0 { words.append(TranscriptWord(text: " ", start: time, end: time, speakerLabel: "speaker_0")) }
                words.append(TranscriptWord(text: String(token), start: time, end: time + step, speakerLabel: "speaker_0"))
                time += step
            }
            return words
        }
        let head = english("Thanks, let's move on.", from: 40, step: 0)
        let collapsed = english("The new pricing page goes live next Tuesday morning.", from: 40, step: 0)
        let copy = english("The new pricing page goes live next Tuesday morning.", from: 45, step: 0.3)
        let space = [TranscriptWord(text: " ", start: 40, end: 40, speakerLabel: "speaker_0")]
        let result = CollapsedDuplicateFilter.apply(to: head + space + collapsed + space + copy)
        #expect(text(result.words) == "Thanks, let's move on. The new pricing page goes live next Tuesday morning.")
        // 残ったのは正しい時刻の写し
        #expect(result.words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.start).filter { $0 < 45 }.count == 4)
        #expect(result.removed == collapsed.count + space.count)
    }
}
