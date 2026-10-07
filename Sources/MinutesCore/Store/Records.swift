import Foundation
import GRDB

// SPEC §7.1 のテーブルに対応するレコード。列名は snake_case、日時は ISO 8601（UTC）。

public enum PrivacyMode: String, Codable, Sendable, CaseIterable {
    case cloudOk = "cloud_ok"
    case localOnly = "local_only"
}

public enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    case recording, finalizing, done, failed
}

public enum MeetingPlatform: String, Codable, Sendable, CaseIterable {
    case meet, teams, other
}

public enum SegmentSource: String, Codable, Sendable {
    case live, final
}

public struct Attendee: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var email: String?

    public init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

/// GRDB レコード共通設定（snake_case 列、ISO 8601 日時）。
public protocol MinutesRecord: Codable, FetchableRecord, PersistableRecord, Sendable {}

/// 自動採番（INTEGER PRIMARY KEY）のレコード。insert 後に id が入る。
public protocol MinutesAutoIDRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {}

// GRDB 7 の要件名: databaseColumn{En,De}codingStrategy（static var）、databaseDate{En,De}codingStrategy(for:)（static func）
public extension MinutesRecord {
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .iso8601 }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .iso8601 }
}

public extension MinutesAutoIDRecord {
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .iso8601 }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .iso8601 }
}

public struct MeetingRecord: MinutesRecord, Identifiable, Equatable {
    public static let databaseTableName = "meetings"

    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var platform: String?
    public var calendarEventId: String?
    public var calendarTitle: String?
    public var attendeesJson: String?
    public var privacyMode: String
    public var status: String
    public var audioDir: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// 録音タイムラインの原点（ファイル先頭の時刻）。会議の開始（`startedAt`）が音声検知で後になる場合に差が生じる。旧行では nil。
    public var recordingStartedAt: Date?
    /// タグ（JSON 配列）。スマートフォルダ「タグ」と検索に使う。
    public var tagsJson: String?
    /// 会議の言語（ISO 639-1、`MeetingLanguage`）。nil はまだ決まっていない（自動。言語を持つ前の会議は日本語で処理した）。
    public var language: String?
    /// `language` を会議のあとの自動判定で決めた（録音中の切り替えや会議の詳細で選んだときは false）。
    public var languageDetected: Bool
    /// 要約の言語（ISO 639-1）。nil は日本語。文字起こしのときに会議の言語と設定から決める。
    public var summaryLanguage: String?

    public init(id: String = ULID.generate(), title: String, startedAt: Date, endedAt: Date? = nil, platform: MeetingPlatform? = nil, calendarEventId: String? = nil, calendarTitle: String? = nil, attendees: [Attendee] = [], privacyMode: PrivacyMode, status: MeetingStatus, audioDir: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), recordingStartedAt: Date? = nil, tags: [String] = [], language: MeetingLanguage? = nil, languageDetected: Bool = false, summaryLanguage: MeetingLanguage? = nil) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recordingStartedAt = recordingStartedAt
        self.tagsJson = MeetingRecord.encodeTags(tags)
        self.language = language?.rawValue
        self.languageDetected = languageDetected
        self.summaryLanguage = summaryLanguage?.rawValue
        self.platform = platform?.rawValue
        self.calendarEventId = calendarEventId
        self.calendarTitle = calendarTitle
        self.attendeesJson = MeetingRecord.encodeAttendees(attendees)
        self.privacyMode = privacyMode.rawValue
        self.status = status.rawValue
        self.audioDir = audioDir
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var privacy: PrivacyMode {
        get { PrivacyMode(rawValue: privacyMode) ?? .cloudOk }
        set { privacyMode = newValue.rawValue }
    }

    public var meetingStatus: MeetingStatus {
        get { MeetingStatus(rawValue: status) ?? .failed }
        set { status = newValue.rawValue }
    }

    public var meetingPlatform: MeetingPlatform? {
        get { platform.flatMap(MeetingPlatform.init(rawValue:)) }
        set { platform = newValue?.rawValue }
    }

    public var attendees: [Attendee] {
        get {
            guard let attendeesJson, let data = attendeesJson.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Attendee].self, from: data)) ?? []
        }
        set { attendeesJson = MeetingRecord.encodeAttendees(newValue) }
    }

    public var audioDirectoryURL: URL? { audioDir.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// 文字起こしに使う言語。決まっていなければ日本語（言語を持つ前の会議も日本語で処理した）。
    public var meetingLanguage: MeetingLanguage { MeetingLanguage(code: language) ?? .ja }

    /// 要約と書き出しの見出しの言語。
    public var summaryOutputLanguage: MeetingLanguage { MeetingLanguage(code: summaryLanguage) ?? .ja }

    /// 録音ファイル先頭から会議開始までの秒数。録音準備（armed）中に録った区間で、mic の文字起こしから除外する。
    public var meetingStartOffsetSeconds: Double {
        guard let recordingStartedAt else { return 0 }
        return max(0, startedAt.timeIntervalSince(recordingStartedAt))
    }

    public var tags: [String] {
        get {
            guard let tagsJson, let data = tagsJson.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set { tagsJson = MeetingRecord.encodeTags(newValue) }
    }

    /// 前後の空白を除き、空と重複を落とす（順序は保つ）。
    public static func normalizeTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { raw in
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            guard !tag.isEmpty, !seen.contains(tag) else { return nil }
            seen.insert(tag)
            return tag
        }
    }

    static func encodeTags(_ tags: [String]) -> String? {
        let cleaned = normalizeTags(tags)
        guard !cleaned.isEmpty, let data = try? JSONEncoder().encode(cleaned) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func encodeAttendees(_ attendees: [Attendee]) -> String? {
        guard !attendees.isEmpty, let data = try? JSONEncoder().encode(attendees) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct SegmentRecord: MinutesAutoIDRecord, Identifiable, Equatable {
    public static let databaseTableName = "segments"

    public var id: Int64?
    public var meetingId: String
    public var source: String
    public var tStart: Double
    public var tEnd: Double
    public var speakerId: String?
    /// プロバイダの話者ラベル（spk_0 等）/ 'me'
    public var clusterLabel: String?
    public var text: String
    public var confidence: Double?
    public var originalText: String?
    public var isCurrent: Bool = true

    public init(id: Int64? = nil, meetingId: String, source: SegmentSource, tStart: Double, tEnd: Double, speakerId: String? = nil, clusterLabel: String? = nil, text: String, confidence: Double? = nil) {
        self.id = id
        self.meetingId = meetingId
        self.source = source.rawValue
        self.tStart = tStart
        self.tEnd = tEnd
        self.speakerId = speakerId
        self.clusterLabel = clusterLabel
        self.text = text
        self.confidence = confidence
        self.originalText = text
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// 発話の話者: 発話単位の変更（speaker_id）を優先し、なければクラスタの話者。
    public func speaker(in speakers: [SpeakerRecord]) -> SpeakerRecord? {
        if let speakerId, let found = speakers.first(where: { $0.id == speakerId }) { return found }
        if let clusterLabel { return speakers.first { $0.clusterLabel == clusterLabel } }
        return nil
    }
}

public struct SpeakerRecord: MinutesRecord, Identifiable, Equatable {
    public static let databaseTableName = "speakers"

    public var id: String
    public var meetingId: String
    public var clusterLabel: String
    public var personId: String?
    public var displayName: String?
    /// 相手側（system）の話者の音量（dBFS）。後処理で測る。自分の声・発話単位の割当用の行・未測定は nil（`BackgroundVoices`）。
    public var levelDb: Double?
    /// 背景の声として除外した。本文では折りたたみ、要約・書き出し・検索から外す。発話単位でこの話者に移した発話も同じ。
    public var excluded: Bool = false

    public init(id: String = ULID.generate(), meetingId: String, clusterLabel: String, personId: String? = nil, displayName: String? = nil, levelDb: Double? = nil, excluded: Bool = false) {
        self.id = id
        self.meetingId = meetingId
        self.clusterLabel = clusterLabel
        self.personId = personId
        self.displayName = displayName
        self.levelDb = levelDb
        self.excluded = excluded
    }

    /// 表示用の名前（未割当ならクラスタラベル）。
    public var label: String { displayName ?? clusterLabel }
}

public struct VoiceSample: Codable, Sendable, Equatable {
    public var path: String
    public var duration: Double
    public var meetingId: String

    public init(path: String, duration: Double, meetingId: String) {
        self.path = path
        self.duration = duration
        self.meetingId = meetingId
    }
}

public struct PersonRecord: MinutesRecord, Identifiable, Equatable {
    public static let databaseTableName = "people"

    public var id: String
    public var name: String
    public var email: String?
    public var aliasesJson: String?
    public var voiceSamplesJson: String?
    public var createdAt: Date

    public init(id: String = ULID.generate(), name: String, email: String? = nil, aliases: [String] = [], voiceSamples: [VoiceSample] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.email = email
        self.aliasesJson = aliases.isEmpty ? nil : PersonRecord.encode(aliases)
        self.voiceSamplesJson = voiceSamples.isEmpty ? nil : PersonRecord.encode(voiceSamples)
        self.createdAt = createdAt
    }

    public var aliases: [String] {
        get { PersonRecord.decode(aliasesJson) ?? [] }
        set { aliasesJson = newValue.isEmpty ? nil : PersonRecord.encode(newValue) }
    }

    public var voiceSamples: [VoiceSample] {
        get { PersonRecord.decode(voiceSamplesJson) ?? [] }
        set { voiceSamplesJson = newValue.isEmpty ? nil : PersonRecord.encode(newValue) }
    }

    static func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func decode<T: Decodable>(_ json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

public struct NotesRecord: MinutesRecord, Equatable {
    public static let databaseTableName = "notes"

    public var meetingId: String
    public var summaryMd: String?
    public var decisionsJson: String?
    public var actionItemsJson: String?
    public var openQuestionsJson: String?
    public var userNotesMd: String?
    /// 'claude-sonnet-5 / prompt v1' など
    public var model: String?
    public var generatedAt: Date?
    /// 要約生成時の入力（本文・話者名・タイトル）のハッシュ。現在の本文と違えば要約が古い。
    public var inputFingerprint: String?

    public init(meetingId: String, summaryMd: String? = nil, decisionsJson: String? = nil, actionItemsJson: String? = nil, openQuestionsJson: String? = nil, userNotesMd: String? = nil, model: String? = nil, generatedAt: Date? = nil, inputFingerprint: String? = nil) {
        self.meetingId = meetingId
        self.summaryMd = summaryMd
        self.decisionsJson = decisionsJson
        self.actionItemsJson = actionItemsJson
        self.openQuestionsJson = openQuestionsJson
        self.userNotesMd = userNotesMd
        self.model = model
        self.generatedAt = generatedAt
        self.inputFingerprint = inputFingerprint
    }

    public var decisions: [MinutesSummary.Decision] { NotesRecord.decode(decisionsJson) ?? [] }
    public var actionItems: [MinutesSummary.ActionItem] { NotesRecord.decode(actionItemsJson) ?? [] }
    public var openQuestions: [MinutesSummary.OpenQuestion] { NotesRecord.decode(openQuestionsJson) ?? [] }

    /// 要約の構造化出力から notes を作る。
    public init(meetingId: String, summary: MinutesSummary, model: String, generatedAt: Date = Date(), userNotesMd: String? = nil, inputFingerprint: String? = nil) {
        self.meetingId = meetingId
        self.summaryMd = summary.summaryMd
        self.decisionsJson = NotesRecord.encode(summary.decisions)
        self.actionItemsJson = NotesRecord.encode(summary.actionItems)
        self.openQuestionsJson = NotesRecord.encode(summary.openQuestions)
        self.userNotesMd = userNotesMd
        self.model = model
        self.generatedAt = generatedAt
        self.inputFingerprint = inputFingerprint
    }

    /// アクション一覧を差し替える（完了チェック・手動追加用）。
    public mutating func setActionItems(_ items: [MinutesSummary.ActionItem]) {
        actionItemsJson = NotesRecord.encode(items)
    }

    /// notes から要約構造を復元する（export 用）。
    public var summary: MinutesSummary? {
        guard summaryMd != nil || decisionsJson != nil || actionItemsJson != nil else { return nil }
        return MinutesSummary(summaryMd: summaryMd ?? "", decisions: decisions, actionItems: actionItems, openQuestions: openQuestions, keytermsLearned: [])
    }

    static func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONCoding.encoder(pretty: false).encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func decode<T: Decodable>(_ json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONCoding.decoder().decode(T.self, from: data)
    }
}

public enum PipelineRunStatus: String, Codable, Sendable {
    case running, ok, failed, invalidated
}

public struct PipelineRunRecord: MinutesAutoIDRecord, Identifiable, Equatable {
    public static let databaseTableName = "pipeline_runs"

    public var id: Int64?
    public var meetingId: String
    public var step: String
    public var status: String
    public var provider: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var error: String?
    public var fingerprint: String?

    public init(id: Int64? = nil, meetingId: String, step: String, status: PipelineRunStatus, provider: String? = nil, startedAt: Date? = Date(), finishedAt: Date? = nil, error: String? = nil) {
        self.id = id
        self.meetingId = meetingId
        self.step = step
        self.status = status.rawValue
        self.provider = provider
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
    }

    public var runStatus: PipelineRunStatus { PipelineRunStatus(rawValue: status) ?? .failed }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public enum ExportStatus: String, Codable, Sendable {
    case ok, pending, failed
}

public struct ExportLogRecord: MinutesAutoIDRecord, Identifiable, Equatable {
    public static let databaseTableName = "export_log"

    public var id: Int64?
    public var meetingId: String
    public var target: String
    public var exportedAt: Date
    public var checksum: String?
    public var status: String

    public init(id: Int64? = nil, meetingId: String, target: String, exportedAt: Date = Date(), checksum: String? = nil, status: ExportStatus) {
        self.id = id
        self.meetingId = meetingId
        self.target = target
        self.exportedAt = exportedAt
        self.checksum = checksum
        self.status = status.rawValue
    }

    public var exportStatus: ExportStatus { ExportStatus(rawValue: status) ?? .failed }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct KeytermRecord: MinutesRecord, Equatable {
    public static let databaseTableName = "keyterms"

    public var term: String
    /// 'manual' | 'attendee' | 'learned'
    public var source: String
    public var createdAt: Date

    public init(term: String, source: String, createdAt: Date = Date()) {
        self.term = term
        self.source = source
        self.createdAt = createdAt
    }
}
