import Foundation
import MinutesCore
import Testing

@Suite("SegmentFolder")
struct SegmentFolderTests {
    func word(_ text: String, _ start: Double, _ end: Double, _ speaker: String? = nil, confidence: Double? = nil) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end, speakerLabel: speaker, confidence: confidence)
    }

    @Test("話者が変わったら区切る")
    func speakerChange() {
        let words = [word("おはよう", 0, 0.5, "a"), word("ございます", 0.5, 1.0, "a"), word("はい", 1.1, 1.4, "b")]
        let segments = SegmentFolder.fold(words: words)
        #expect(segments.count == 2)
        #expect(segments[0].text == "おはようございます")
        #expect(segments[0].speakerLabel == "a")
        #expect(segments[1].speakerLabel == "b")
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 1.0)
    }

    @Test("長い無音で区切る")
    func pause() {
        var options = SegmentFoldingOptions()
        options.maxPause = 1.0
        let words = [word("a", 0, 0.5, "a"), word("b", 0.6, 1.0, "a"), word("c", 2.5, 3.0, "a")]
        let segments = SegmentFolder.fold(words: words, options: options)
        #expect(segments.count == 2)
        #expect(segments[1].text == "c")
    }

    @Test("文末記号 + 一定長で区切り、話者 nil は引き継ぐ")
    func sentenceSplit() {
        var options = SegmentFoldingOptions()
        options.sentenceSplitMinDuration = 2
        let words = [word("今日は。", 0, 2.5, "a"), word("明日は", 2.6, 3.0), word("。", 3.0, 3.1, "a")]
        let segments = SegmentFolder.fold(words: words, options: options)
        #expect(segments.count == 2)
        #expect(segments[1].text == "明日は。")
        #expect(segments[1].speakerLabel == "a")
    }

    @Test("信頼度は平均、空テキストは捨てる")
    func confidence() {
        let words = [word("a", 0, 0.5, "a", confidence: 0.8), word("b", 0.5, 1.0, "a", confidence: 0.6), word(" ", 1.0, 1.0, "a")]
        let segments = SegmentFolder.fold(words: words)
        #expect(segments.count == 1)
        #expect(segments[0].confidence.map { abs($0 - 0.7) < 1e-9 } == true)
        #expect(SegmentFolder.fold(words: [word("  ", 0, 1)]).isEmpty)
    }
}
