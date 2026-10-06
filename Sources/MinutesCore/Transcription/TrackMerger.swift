import Foundation

/// mic（"me"）と system（spk_n）の結果を時刻でマージする（SPEC §8 merge_tracks）。重なりは両方残す。
public enum TrackMerger {
    public static let systemTrack = "system"
    public static let micTrack = "mic"
    public static let micSpeakerLabel = "me"

    public struct Input: Sendable {
        public var system: TranscriptionResult?
        public var mic: TranscriptionResult?

        public init(system: TranscriptionResult?, mic: TranscriptionResult?) {
            self.system = system
            self.mic = mic
        }
    }

    public struct Output: Sendable, Equatable, Codable {
        public var speakers: [TranscriptDocument.Speaker]
        public var segments: [TranscriptDocument.Segment]
    }

    public static func merge(_ input: Input) -> Output {
        var speakers: [TranscriptDocument.Speaker] = []
        var pending: [(track: String, segment: TranscriptSegment, speaker: String?)] = []

        if let system = input.system {
            var normalizer = SpeakerLabelNormalizer()
            for segment in system.segments {
                let label = normalizer.label(for: segment.speakerLabel)
                pending.append((systemTrack, segment, label))
            }
            for provider in normalizer.order {
                let label = normalizer.mapping[provider] ?? provider
                speakers.append(TranscriptDocument.Speaker(label: label, providerLabel: provider, track: systemTrack))
            }
        }
        if let mic = input.mic, !mic.segments.isEmpty {
            for segment in mic.segments {
                pending.append((micTrack, segment, micSpeakerLabel))
            }
            speakers.append(TranscriptDocument.Speaker(label: micSpeakerLabel, providerLabel: nil, track: micTrack))
        }

        // 開始時刻で安定ソート（同時刻は system を先に）
        let sorted = pending.enumerated().sorted { lhs, rhs in
            if lhs.element.segment.start != rhs.element.segment.start { return lhs.element.segment.start < rhs.element.segment.start }
            if lhs.element.track != rhs.element.track { return lhs.element.track == systemTrack }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let segments = sorted.enumerated().map { index, item in
            TranscriptDocument.Segment(
                id: index + 1,
                track: item.track,
                tStart: item.segment.start,
                tEnd: item.segment.end,
                speaker: item.speaker,
                text: item.segment.text,
                confidence: item.segment.confidence
            )
        }
        return Output(speakers: speakers, segments: segments)
    }
}
