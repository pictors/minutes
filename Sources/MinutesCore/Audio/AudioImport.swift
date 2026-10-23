import AVFoundation
import Foundation

/// 外部の録音（Apple Watch のボイスメモなど）を会議として取り込む（SPEC §4.4）。
/// 音声全体を 1 本の system トラックにし（部屋の全員を話者分離で分ける）、会議の行と後処理の依頼を同時に作る。元のファイルは動かさない。
/// 確認済みの API（AVFoundation の swiftinterface）: `AVAsset.load(.creationDate)` → `AVMetadataItem?`、`AVMetadataItem.load(.dateValue)` → `Date?`。
public enum AudioImport {
    /// 取り込む前に読む音声の情報。
    public struct Probe: Sendable, Equatable {
        public var duration: Double
        /// 録った日時（音声のメタデータの作成日時、なければファイルの作成日時）。
        public var recordedAt: Date?

        public init(duration: Double, recordedAt: Date?) {
            self.duration = duration
            self.recordedAt = recordedAt
        }
    }

    /// 確認のシートで決めた会議の情報。
    public struct Details: Sendable {
        public var title: String
        public var startedAt: Date
        public var language: MeetingLanguage
        public var privacy: PrivacyMode
        public var platform: MeetingPlatform?
        public var calendarEventId: String?
        public var calendarTitle: String?
        public var attendees: [Attendee]

        public init(title: String, startedAt: Date, language: MeetingLanguage, privacy: PrivacyMode, platform: MeetingPlatform? = nil,
                    calendarEventId: String? = nil, calendarTitle: String? = nil, attendees: [Attendee] = []) {
            self.title = title
            self.startedAt = startedAt
            self.language = language
            self.privacy = privacy
            self.platform = platform
            self.calendarEventId = calendarEventId
            self.calendarTitle = calendarTitle
            self.attendees = attendees
        }
    }

    public enum ImportError: LocalizedError, Equatable {
        case unreadable(String)
        case tooShort(String)

        public var errorDescription: String? {
            switch self {
            case let .unreadable(name): "\(name) は音声として読めません（m4a・mp3・wav・aiff・caf を取り込めます）"
            case let .tooShort(name): "\(name) は短すぎます（1 秒以上の音声を取り込めます）"
            }
        }
    }

    public static let minimumDuration: Double = 1
    /// 保存用の system.m4a のビットレート（16 kHz mono。録音の 48 kHz・64 kbps より小さくてよい）。
    static let archiveBitrate = 32_000

    public static func probe(_ url: URL) async throws -> Probe {
        let duration: Double
        do { duration = try AudioFileTools.duration(of: url) } catch { throw ImportError.unreadable(url.lastPathComponent) }
        guard duration >= minimumDuration else { throw ImportError.tooShort(url.lastPathComponent) }
        var recordedAt: Date?
        if let item = (try? await AVURLAsset(url: url).load(.creationDate)) ?? nil {
            recordedAt = (try? await item.load(.dateValue)) ?? nil
        }
        if recordedAt == nil {
            recordedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
        }
        return Probe(duration: duration, recordedAt: recordedAt)
    }

    /// 音声を `audioRoot/<会議 id>/` に写して会議を作り、後処理を依頼する。音声全体を読み込むので、呼び出し側は main の外で呼ぶ。
    @discardableResult
    public static func importMeeting(from source: URL, details: Details, store: Store, audioRoot: URL) throws -> MeetingRecord {
        let samples: [Float]
        do { samples = try AudioFileTools.loadMono16k(source) } catch { throw ImportError.unreadable(source.lastPathComponent) }
        let duration = Double(samples.count) / AudioFileTools.sttSampleRate
        guard duration >= minimumDuration else { throw ImportError.tooShort(source.lastPathComponent) }
        let id = ULID.generate()
        let directory = audioRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try AudioFileTools.writeWAV(samples: samples, sampleRate: AudioFileTools.sttSampleRate,
                                        to: directory.appendingPathComponent(RecordingSession.systemSTTName))
            try AudioFileTools.writeAAC(samples: samples, sampleRate: AudioFileTools.sttSampleRate,
                                        to: directory.appendingPathComponent(RecordingSession.systemArchiveName), bitrate: archiveBitrate)
            // 録音の原点と会議の開始を同じにする（違うと録音準備中の切り落としで冒頭が消える）
            let record = MeetingRecord(
                id: id,
                title: details.title,
                startedAt: details.startedAt,
                endedAt: details.startedAt.addingTimeInterval(duration),
                platform: details.platform,
                calendarEventId: details.calendarEventId,
                calendarTitle: details.calendarTitle,
                attendees: details.attendees,
                privacyMode: details.privacy,
                status: .finalizing,
                audioDir: directory.path,
                recordingStartedAt: details.startedAt,
                language: details.language
            )
            return try store.createMeetingForPostProcessing(record)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// 録音と最も長く重なる予定。重なりが録音の半分（長い録音では 5 分）に満たない予定は選ばない。
    public static func bestOverlap<T>(_ candidates: [T], start: Date, duration: Double, interval: (T) -> DateInterval) -> T? {
        let recording = DateInterval(start: start, duration: max(0, duration))
        let required = min(recording.duration / 2, 300)
        var best: (item: T, overlap: Double)?
        for candidate in candidates {
            guard let overlap = recording.intersection(with: interval(candidate))?.duration, overlap > 0, overlap >= required else { continue }
            if overlap > best?.overlap ?? 0 { best = (candidate, overlap) }
        }
        return best?.item
    }

    /// ファイル名から題名を作る（拡張子を外す）。
    public static func defaultTitle(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "取り込んだ録音" : name
    }
}
