import CryptoKit
import Foundation

/// 書き出しフォルダの manifest（SPEC §7.3）。
public struct ExportManifest: Codable, Sendable, Equatable {
    public struct FileEntry: Codable, Sendable, Equatable {
        public var sha256: String
        public var bytes: Int
    }

    public static let currentSchemaVersion = 1
    public static let fileName = "manifest.json"

    public var schemaVersion: Int
    public var meetingId: String
    public var folder: String
    public var generatedAt: Date
    public var generatedBy: String
    public var files: [String: FileEntry]

    public init(meetingId: String, folder: String, generatedAt: Date, generatedBy: String, files: [String: FileEntry]) {
        self.schemaVersion = ExportManifest.currentSchemaVersion
        self.meetingId = meetingId
        self.folder = folder
        self.generatedAt = generatedAt
        self.generatedBy = generatedBy
        self.files = files
    }

    /// フォルダ全体の checksum（ファイル名順に sha256 を連結して sha256）。
    public var checksum: String {
        let joined = files.keys.sorted().map { "\($0):\(files[$0]!.sha256)" }.joined(separator: "\n")
        return MeetingExporter.sha256Hex(Data(joined.utf8))
    }

    public static func read(from directory: URL) throws -> ExportManifest {
        try JSONCoding.decoder().decode(ExportManifest.self, from: Data(contentsOf: directory.appendingPathComponent(fileName)))
    }

    /// manifest に記録された sha256 とファイルの実体を照合する。
    public static func verify(directory: URL) throws -> ExportManifest {
        let manifest = try read(from: directory)
        for (name, entry) in manifest.files {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            guard MeetingExporter.sha256Hex(data) == entry.sha256 else {
                throw ExportError.checksumMismatch(name)
            }
        }
        return manifest
    }
}

public enum ExportError: Error, LocalizedError, Equatable {
    case checksumMismatch(String)
    case destinationUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .checksumMismatch(name): return "\(name) の sha256 が manifest と一致しません"
        case let .destinationUnavailable(path): return "書き出し先が使えません: \(path)"
        }
    }
}

/// 1 会議 = 1 フォルダの書き出し（SPEC §7.3）。
public struct ExportBundle: Sendable {
    public var folderName: String
    public var files: [(name: String, data: Data)]
    public var manifest: ExportManifest

    /// フォルダを `parent/<folderName>/` に書く（一時フォルダに書いてから置き換える）。
    @discardableResult
    public func write(into parent: URL) throws -> URL {
        let destination = parent.appendingPathComponent(folderName, isDirectory: true)
        let temporary = parent.appendingPathComponent(".\(folderName).tmp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        for file in files {
            try file.data.write(to: temporary.appendingPathComponent(file.name), options: .atomic)
        }
        try JSONCoding.encoder().encode(manifest).write(to: temporary.appendingPathComponent(ExportManifest.fileName), options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

public enum MeetingExporter {
    public static let generatorName = "minutes/0.1"

    /// `YYYY-MM-DD_HHmm_<slug>_<id8>`
    public static func folderName(meeting: MeetingRecord) -> String {
        "\(JSONCoding.folderTimestamp(meeting.startedAt))_\(slug(meeting.title))_\(meeting.id.suffix(8).lowercased())"
    }

    /// タイトルをファイル名向けにする。日本語はそのまま、空白・記号は '-'、最大 40 文字。
    public static func slug(_ title: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in title.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        if result.isEmpty { result = "meeting" }
        return String(result.prefix(40))
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public struct Input: Sendable {
        public var meeting: MeetingRecord
        public var speakers: [SpeakerRecord]
        public var segments: [SegmentRecord]
        public var notes: NotesRecord?
        public var providerDescription: String

        public init(meeting: MeetingRecord, speakers: [SpeakerRecord], segments: [SegmentRecord], notes: NotesRecord?, providerDescription: String) {
            self.meeting = meeting
            self.speakers = speakers
            self.segments = segments
            self.notes = notes
            self.providerDescription = providerDescription
        }
    }

    public static func build(_ input: Input, now: Date = Date()) throws -> ExportBundle {
        let meeting = input.meeting
        let speakerBySegmentSpeakerId = Dictionary(uniqueKeysWithValues: input.speakers.map { ($0.id, $0) })
        let speakerByCluster = Dictionary(uniqueKeysWithValues: input.speakers.map { ($0.clusterLabel, $0) })
        // 背景の声として除外した話者は、発話も話者の一覧も書き出さない
        let segments = BackgroundVoices.removingExcluded(input.segments, speakers: input.speakers)
        let speakers = input.speakers.filter { !$0.excluded }

        func displayName(for segment: SegmentRecord) -> String {
            if let id = segment.speakerId, let speaker = speakerBySegmentSpeakerId[id] { return speaker.label }
            if let cluster = segment.clusterLabel, let speaker = speakerByCluster[cluster] { return speaker.label }
            return segment.clusterLabel ?? "?"
        }

        // transcript.json
        let document = TranscriptDocument(
            meeting: .init(id: meeting.id, title: meeting.title, startedAt: meeting.startedAt, durationSeconds: input.segments.map(\.tEnd).max(), sourceDirectory: nil),
            provider: input.providerDescription,
            language: meeting.meetingLanguage.rawValue,
            speakers: speakers.map { .init(label: $0.clusterLabel, name: $0.displayName, providerLabel: nil, track: $0.clusterLabel == TrackMerger.micSpeakerLabel ? TrackMerger.micTrack : TrackMerger.systemTrack) },
            segments: segments.map { segment in
                .init(id: Int(segment.id ?? 0), track: segment.clusterLabel == TrackMerger.micSpeakerLabel ? TrackMerger.micTrack : TrackMerger.systemTrack,
                      tStart: segment.tStart, tEnd: segment.tEnd, speaker: displayName(for: segment), text: segment.text, confidence: segment.confidence)
            },
            providerMeta: [:],
            createdAt: now
        )
        let transcriptData = try JSONCoding.encoder().encode(document)
        let transcriptSha = sha256Hex(transcriptData)

        // summary.json
        let summary = input.notes?.summary
        let summaryData = try summary.map { try JSONCoding.encoder().encode($0) }

        // meeting.md
        let markdown = renderMarkdown(meeting: meeting, speakers: speakers, segments: segments, notes: input.notes, transcriptSha256: transcriptSha, generatedBy: "\(generatorName) (\(input.providerDescription)\(input.notes?.model.map { ", \($0)" } ?? ""))", displayName: displayName)
        let markdownData = Data(markdown.utf8)

        var files: [(name: String, data: Data)] = [("meeting.md", markdownData), ("transcript.json", transcriptData)]
        if let summaryData { files.append(("summary.json", summaryData)) }
        let folder = folderName(meeting: meeting)
        let manifest = ExportManifest(
            meetingId: meeting.id,
            folder: folder,
            generatedAt: now,
            generatedBy: generatorName,
            files: Dictionary(uniqueKeysWithValues: files.map { ($0.name, ExportManifest.FileEntry(sha256: sha256Hex($0.data), bytes: $0.data.count)) })
        )
        return ExportBundle(folderName: folder, files: files, manifest: manifest)
    }

    static func yamlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func renderMarkdown(meeting: MeetingRecord, speakers: [SpeakerRecord], segments: [SegmentRecord], notes: NotesRecord?, transcriptSha256: String, generatedBy: String, displayName: (SegmentRecord) -> String) -> String {
        var lines: [String] = ["---"]
        lines.append("id: \(meeting.id)")
        lines.append("title: \(yamlString(meeting.title))")
        lines.append("started_at: \(JSONCoding.iso8601Local(meeting.startedAt))")
        if let ended = meeting.endedAt { lines.append("ended_at: \(JSONCoding.iso8601Local(ended))") }
        lines.append("platform: \(meeting.platform ?? "other")")
        if let eventId = meeting.calendarEventId { lines.append("calendar_event_id: \(yamlString(eventId))") }
        let attendees = meeting.attendees
        if attendees.isEmpty {
            lines.append("attendees: []")
        } else {
            lines.append("attendees:")
            for attendee in attendees {
                lines.append("  - {name: \(yamlString(attendee.name)), email: \(yamlString(attendee.email ?? ""))}")
            }
        }
        let tags = meeting.tags
        if tags.isEmpty {
            lines.append("tags: []")
        } else {
            lines.append("tags: [" + tags.map(yamlString).joined(separator: ", ") + "]")
        }
        if speakers.isEmpty {
            lines.append("speakers: []")
        } else {
            lines.append("speakers:")
            for speaker in speakers {
                lines.append("  - {label: \(speaker.clusterLabel), name: \(yamlString(speaker.displayName ?? ""))}")
            }
        }
        lines.append("privacy_mode: \(meeting.privacyMode)")
        lines.append("language: \(meeting.meetingLanguage.rawValue)")
        lines.append("transcript_sha256: \(transcriptSha256)")
        lines.append("generated_by: \(yamlString(generatedBy))")
        lines.append("---")
        lines.append("")
        // 見出しは要約の言語に合わせる（英語で要約した会議は英語の見出し。2026-10-07 決定）
        let label = Labels(meeting.summaryOutputLanguage)
        lines.append("# \(meeting.title)")
        lines.append("")
        lines.append("## \(label.summary)")
        lines.append("")
        lines.append(notes?.summaryMd?.isEmpty == false ? notes!.summaryMd! : label.noSummary)
        lines.append("")
        lines.append("## \(label.decisions)")
        lines.append("")
        let decisions = notes?.decisions ?? []
        lines.append(contentsOf: decisions.isEmpty ? [label.none] : decisions.map { "- \($0.text)\(label.paren("evidence: \(evidenceText($0.evidence))"))" })
        lines.append("")
        lines.append("## \(label.actions)")
        lines.append("")
        let actions = notes?.actionItems ?? []
        lines.append(contentsOf: actions.isEmpty ? [label.none] : actions.map {
            "- [\($0.done == true ? "x" : " ")] \($0.text)\(label.paren("owner: \($0.owner) / kind: \($0.kind.rawValue) / due: \($0.due ?? "-") / evidence: \(evidenceText($0.evidence))"))"
        })
        lines.append("")
        lines.append("## \(label.openQuestions)")
        lines.append("")
        let questions = notes?.openQuestions ?? []
        lines.append(contentsOf: questions.isEmpty ? [label.none] : questions.map { "- \($0.text)\(label.paren("evidence: \(evidenceText($0.evidence))"))" })
        if let userNotes = notes?.userNotesMd, !userNotes.isEmpty {
            lines.append("")
            lines.append("## \(label.notes)")
            lines.append("")
            lines.append(userNotes)
        }
        lines.append("")
        lines.append("## \(label.transcript)")
        lines.append("")
        for segment in segments {
            lines.append("[\(TimeFormatting.hms(segment.tStart))] \(displayName(segment)): \(segment.text)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func evidenceText(_ ids: [Int]) -> String {
        ids.isEmpty ? "-" : ids.map { "seg#\($0)" }.joined(separator: ", ")
    }

    /// meeting.md の見出しと定型の言葉（要約の言語ごと）。
    struct Labels {
        var summary, noSummary, decisions, actions, openQuestions, notes, transcript, none: String
        var paren: (String) -> String

        init(_ language: MeetingLanguage) {
            switch language {
            case .ja:
                (summary, noSummary, decisions, actions, openQuestions, notes, transcript, none) =
                    ("要約", "（要約なし）", "決定事項", "アクション", "未決・論点", "メモ", "全文（話者付き）", "（なし）")
                paren = { "（\($0)）" }
            case .en:
                (summary, noSummary, decisions, actions, openQuestions, notes, transcript, none) =
                    ("Summary", "(No summary)", "Decisions", "Action items", "Open questions", "Notes", "Transcript", "(None)")
                paren = { " (\($0))" }
            }
        }
    }
}

// MARK: - SyncTarget (SPEC §9.1)

public struct SyncReceipt: Sendable, Equatable {
    public var targetId: String
    public var location: String
    public var checksum: String
    public var uploadedAt: Date
}

public protocol SyncTarget: Sendable {
    var id: String { get }
    var cacheIdentity: String { get }
    func upload(folder: URL, manifest: ExportManifest) async throws -> SyncReceipt
    /// 会議の書き出しを同期先から取り消す（ローカル専用への切替時）。対応しない同期先は空配列を返す。削除したパスを返す。
    func remove(meeting: MeetingRecord) async throws -> [String]
}

public extension SyncTarget {
    var cacheIdentity: String { id }
    func remove(meeting: MeetingRecord) async throws -> [String] { [] }
}

public extension MeetingExporter {
    /// `parent` 直下にある、この会議のフォルダ（末尾が `_<id8>`）を削除する。`except` の名前は残す。削除したパスを返す。
    @discardableResult
    static func removeFolders(for meeting: MeetingRecord, in parent: URL, except keep: String? = nil) throws -> [String] {
        let suffix = "_" + meeting.id.suffix(8).lowercased()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return [] }
        var removed: [String] = []
        for name in entries where name.hasSuffix(suffix) && name != keep && !name.hasPrefix(".") {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.removeItem(at: url)
            removed.append(url.path)
        }
        return removed
    }
}

/// 任意のフォルダにコピーする（Google Drive / Dropbox の同期フォルダを指定すれば、ほかの機器にも届く）。
public struct LocalDirectorySyncTarget: SyncTarget {
    public let id = "local_directory"
    public var destination: URL
    public var cacheIdentity: String { id + "/" + destination.standardizedFileURL.path }

    public init(destination: URL) {
        self.destination = destination
    }

    public func upload(folder: URL, manifest: ExportManifest) async throws -> SyncReceipt {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                throw ExportError.destinationUnavailable(destination.path)
            }
        }
        let target = destination.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        let temporary = destination.appendingPathComponent(".\(folder.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fileManager.removeItem(at: temporary)
        try fileManager.copyItem(at: folder, to: temporary)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: temporary, to: target)
        let verified = try ExportManifest.verify(directory: target)
        // タイトル変更前の名前のコピー（同じ id 末尾）を残さない
        let suffix = "_" + verified.meetingId.suffix(8).lowercased()
        if let entries = try? fileManager.contentsOfDirectory(atPath: destination.path) {
            for name in entries where name.hasSuffix(suffix) && name != folder.lastPathComponent && !name.hasPrefix(".") {
                try? fileManager.removeItem(at: destination.appendingPathComponent(name, isDirectory: true))
            }
        }
        return SyncReceipt(targetId: id, location: target.path, checksum: verified.checksum, uploadedAt: Date())
    }

    public func remove(meeting: MeetingRecord) async throws -> [String] {
        try MeetingExporter.removeFolders(for: meeting, in: destination)
    }
}
