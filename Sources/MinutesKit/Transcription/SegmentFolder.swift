import Foundation

/// word 列を segment に畳む（ElevenLabs の words[]、SpeechAnalyzer の run など）。
public struct SegmentFoldingOptions: Sendable {
    /// これ以上の無音で区切る（秒）。
    public var maxPause: Double = 1.0
    /// これ以上の長さになったら次の区切り候補で分ける（秒）。
    public var maxDuration: Double = 30
    /// 文末記号で終わっていて、かつこの長さ以上なら区切る（秒）。
    public var sentenceSplitMinDuration: Double = 8
    public var sentenceEnders: Set<Character> = ["。", "？", "！", "?", "!", ".", "．"]

    public init() {}
}

public enum SegmentFolder {
    public static func fold(words: [TranscriptWord], options: SegmentFoldingOptions = SegmentFoldingOptions()) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [TranscriptWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let confidences = current.compactMap(\.confidence)
            let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
            if !trimmed.isEmpty {
                segments.append(TranscriptSegment(
                    start: first.start,
                    end: max(last.end, first.start),
                    text: trimmed,
                    speakerLabel: current.compactMap(\.speakerLabel).first,
                    confidence: confidence
                ))
            }
            current.removeAll(keepingCapacity: true)
        }

        for word in words {
            if let last = current.last {
                let speakerChanged = word.speakerLabel != nil && last.speakerLabel != nil && word.speakerLabel != last.speakerLabel
                let pause = word.start - last.end
                let duration = last.end - (current.first?.start ?? last.start)
                let endsSentence = last.text.trimmingCharacters(in: .whitespaces).last.map { options.sentenceEnders.contains($0) } ?? false
                if speakerChanged
                    || pause > options.maxPause
                    || duration >= options.maxDuration
                    || (endsSentence && duration >= options.sentenceSplitMinDuration) {
                    flush()
                }
            }
            current.append(word)
        }
        flush()
        return segments
    }
}
