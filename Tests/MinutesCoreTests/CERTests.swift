import Foundation
import MinutesCore
import Testing

@Suite("CER / 正規化")
struct CERTests {
    @Test("NFKC 正規化と空白・記号の除去")
    func normalization() {
        let scalars = TextNormalizer.normalizeForCER("ＡＢＣ　abc、こんにちは！ 「テスト」… サーバー・メール")
        #expect(String(String.UnicodeScalarView(scalars)) == "abcabcこんにちはテストサーバー・メール")
    }

    @Test("同一文字列の CER は 0")
    func identical() {
        let result = CER.compute(reference: "今日は良い天気です。", hypothesis: "今日は良い天気です")
        #expect(result.editDistance == 0)
        #expect(result.cer == 0)
        #expect(result.referenceLength == 9)
    }

    @Test("置換・削除・挿入をそれぞれ 1 と数える")
    func editDistance() {
        #expect(EditDistance.levenshtein(Array("kitten".unicodeScalars), Array("sitting".unicodeScalars)) == 3)
        #expect(EditDistance.levenshtein(Array("".unicodeScalars), Array("abc".unicodeScalars)) == 3)
        #expect(EditDistance.levenshtein(Array("abc".unicodeScalars), Array("".unicodeScalars)) == 3)
    }

    @Test("CER の計算例")
    func cerValue() {
        // 参照 10 文字、1 文字置換 + 1 文字欠落 → 2/10
        let result = CER.compute(reference: "あいうえおかきくけこ", hypothesis: "あいうえおかきくけ")
        #expect(result.editDistance == 1)
        #expect(abs(result.cer - 0.1) < 1e-9)
        let result2 = CER.compute(reference: "あいうえおかきくけこ", hypothesis: "あいうえおかさくけ")
        #expect(result2.editDistance == 2)
    }

    @Test("参照が空なら仮説があると 1、なければ 0")
    func emptyReference() {
        #expect(CER.compute(reference: "", hypothesis: "abc").cer == 1)
        #expect(CER.compute(reference: "", hypothesis: "").cer == 0)
    }

    @Test("話者プレフィックスとタイムスタンプの除去")
    func stripping() {
        let text = "[00:12:30] 田中: おはようございます\nSpeaker 1： はい\n本文のみ"
        let stripped = TextNormalizer.stripSpeakerPrefixes(TextNormalizer.stripTimestamps(text))
        #expect(stripped.contains("おはようございます"))
        #expect(!stripped.contains("田中"))
        #expect(!stripped.contains("00:12:30"))
        #expect(stripped.contains("本文のみ"))
    }
}
