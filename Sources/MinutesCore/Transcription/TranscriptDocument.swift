import Foundation

/// Phase 0 の統一フォーマット `transcript.json`（SPEC §7.3 の transcript.json と互換の骨格）。
public struct TranscriptDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public struct Meeting: Codable, Sendable, Equatable {
        public var id: String
        public var title: String?
        public var startedAt: Date?
        public var durationSeconds: Double?
        /// 録音フォルダ（相対 or 絶対）。
        public var sourceDirectory: String?

        public init(id: String, title: String? = nil, startedAt: Date? = nil, durationSeconds: Double? = nil, sourceDirectory: String? = nil) {
            self.id = id
            self.title = title
            self.startedAt = startedAt
            self.durationSeconds = durationSeconds
            self.sourceDirectory = sourceDirectory
        }
    }

    public struct Speaker: Codable, Sendable, Equatable {
        /// 正規化ラベル（"spk_0" / "me"）。
        public var label: String
        /// 人間が割り当てた名前（Phase 1 以降）。
        public var name: String?
        /// プロバイダ固有の元ラベル。
        public var providerLabel: String?
        /// "system" | "mic"
        public var track: String

        public init(label: String, name: String? = nil, providerLabel: String? = nil, track: String) {
            self.label = label
            self.name = name
            self.providerLabel = providerLabel
            self.track = track
        }
    }

    public struct Segment: Codable, Sendable, Equatable {
        public var id: Int
        /// "system" | "mic"
        public var track: String
        public var tStart: Double
        public var tEnd: Double
        public var speaker: String?
        public var text: String
        public var confidence: Double?

        public init(id: Int, track: String, tStart: Double, tEnd: Double, speaker: String?, text: String, confidence: Double? = nil) {
            self.id = id
            self.track = track
            self.tStart = tStart
            self.tEnd = tEnd
            self.speaker = speaker
            self.text = text
            self.confidence = confidence
        }
    }

    public var schemaVersion: Int
    public var meeting: Meeting
    /// BatchTranscriber.id
    public var provider: String
    public var language: String
    public var speakers: [Speaker]
    public var segments: [Segment]
    public var providerMeta: [String: String]
    public var createdAt: Date

    public init(meeting: Meeting, provider: String, language: String, speakers: [Speaker], segments: [Segment], providerMeta: [String: String] = [:], createdAt: Date = Date()) {
        self.schemaVersion = TranscriptDocument.currentSchemaVersion
        self.meeting = meeting
        self.provider = provider
        self.language = language
        self.speakers = speakers
        self.segments = segments
        self.providerMeta = providerMeta
        self.createdAt = createdAt
    }

    public func write(to url: URL) throws {
        let data = try JSONCoding.encoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> TranscriptDocument {
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder().decode(TranscriptDocument.self, from: data)
    }

    /// 話者付き全文（"[hh:mm:ss] speaker: text" 形式）。
    public func formattedTranscript() -> String {
        segments.map { segment in
            "[\(TimeFormatting.hms(segment.tStart))] \(segment.speaker ?? "?"): \(segment.text)"
        }.joined(separator: "\n")
    }
}

public enum TimeFormatting {
    /// 秒 → "hh:mm:ss"
    public static func hms(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// 秒 → "m:ss"（1 時間以上は "h:mm:ss"）。メニューバーの経過時間用。
    public static func mmssShort(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 秒 → "mm:ss.t"
    public static func mmss(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let rest = total - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, rest)
    }
}
