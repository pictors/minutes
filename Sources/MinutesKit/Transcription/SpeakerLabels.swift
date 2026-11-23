import Foundation

/// プロバイダ固有の話者 id（"speaker_0"、"A" 等）を出現順に "spk_0", "spk_1", … へ正規化する。
public struct SpeakerLabelNormalizer: Sendable {
    public private(set) var mapping: [String: String] = [:]
    public private(set) var order: [String] = []
    public let prefix: String

    public init(prefix: String = "spk_") {
        self.prefix = prefix
    }

    public mutating func label(for providerLabel: String?) -> String? {
        guard let providerLabel, !providerLabel.isEmpty else { return nil }
        if let existing = mapping[providerLabel] { return existing }
        let label = "\(prefix)\(order.count)"
        mapping[providerLabel] = label
        order.append(providerLabel)
        return label
    }

    /// 正規化後ラベル → 元ラベル。
    public var providerLabelByNormalized: [String: String] {
        var result: [String: String] = [:]
        for (provider, normalized) in mapping { result[normalized] = provider }
        return result
    }
}

/// 話者分離の 1 発話区間。
public struct SpeakerTurn: Sendable, Codable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// 時間重なり最大の話者を割り当てる（SPEC §5.3 Local、§5.4）。
public enum SpeakerOverlap {
    /// [start, end] と最も長く重なる話者を返す。重なりがなければ最近接の区間（`tolerance` 秒以内）を採用する。
    public static func bestSpeaker(start: Double, end: Double, turns: [SpeakerTurn], tolerance: Double = 0.5) -> String? {
        var best: (speaker: String, overlap: Double)? = nil
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) {
                best = (turn.speaker, overlap)
            }
        }
        if let best { return best.speaker }

        // 重なりなし: 最近接（点としての距離）
        var nearest: (speaker: String, distance: Double)? = nil
        for turn in turns {
            let distance: Double
            if end < turn.start { distance = turn.start - end } else if start > turn.end { distance = start - turn.end } else { distance = 0 }
            if distance <= tolerance, distance < (nearest?.distance ?? .infinity) {
                nearest = (turn.speaker, distance)
            }
        }
        return nearest?.speaker
    }

    /// 各 word に話者を割り当てる。割り当てられない word は直前の話者を引き継ぐ。
    public static func assign(words: [TranscriptWord], turns: [SpeakerTurn], tolerance: Double = 0.5) -> [TranscriptWord] {
        var result: [TranscriptWord] = []
        result.reserveCapacity(words.count)
        var last: String? = nil
        for var word in words {
            if let speaker = bestSpeaker(start: word.start, end: word.end, turns: turns, tolerance: tolerance) {
                word.speakerLabel = speaker
                last = speaker
            } else {
                word.speakerLabel = last
            }
            result.append(word)
        }
        return result
    }
}
