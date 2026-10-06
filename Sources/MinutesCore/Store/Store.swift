import Foundation
import GRDB

public enum MeetingFilter: Sendable, Equatable {
    case all
    case today
    case thisWeek
    /// done 以外
    case unprocessed
    /// 録音中・後処理中（失敗は含まない）
    case processing
    case status(MeetingStatus)
    /// タグが付いた会議
    case tag(String)
    /// 指定時刻以降に開始した会議（メニューバーの今日・今週の集計）
    case since(Date)
}

/// タグとその件数（サイドバーのタグ一覧）。
public struct TagCount: Sendable, Equatable, Hashable, Identifiable {
    public var tag: String
    public var count: Int
    public var id: String { tag }

    public init(tag: String, count: Int) {
        self.tag = tag
        self.count = count
    }
}

public struct SearchHit: Sendable, Equatable {
    public var segment: SegmentRecord
    /// ヒットの前後 1 件を含む snippet（時刻順）。
    public var context: [SegmentRecord]
}

public struct SearchResult: Sendable, Equatable {
    public var meeting: MeetingRecord
    public var segmentHits: [SearchHit]
    public var notesMatched: Bool
    /// タイトル・カレンダー名・参加者名・タグにヒットした。
    public var titleMatched: Bool = false
}

/// 会議一覧と、行に添える要約の 1 行目。
public struct MeetingListSnapshot: Sendable, Equatable {
    public var meetings: [MeetingRecord] = []
    /// meeting id → 要約の先頭（120 文字まで）。
    public var previews: [String: String] = [:]

    public init(meetings: [MeetingRecord] = [], previews: [String: String] = [:]) {
        self.meetings = meetings
        self.previews = previews
    }
}

public enum StoreError: Error, LocalizedError {
    case notFound(String)
    case meetingBusy(String)
    case audioDeletionPending(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(what): return "\(what) が見つかりません"
        case .meetingBusy: return "この会議は別の録音・処理で使用中です"
        case let .audioDeletionPending(detail): return "会議の削除は保存しましたが、音声ファイルが残っています。自動で再試行します: \(detail)"
        }
    }
}

/// SQLite ストア（GRDB）。`~/Library/Application Support/Minutes/minutes.sqlite`。
public final class Store: Sendable {
    public let writer: any DatabaseWriter
    private let leaseDirectory: URL

    public static func defaultURL() -> URL {
        applicationSupportDirectory().appendingPathComponent("minutes.sqlite")
    }

    public static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Minutes", isDirectory: true)
    }

    public static func open(at url: URL = defaultURL()) throws -> Store {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        let store = Store(writer: pool, leaseDirectory: url.resolvingSymlinksInPath().appendingPathExtension("locks"))
        try StoreSchema.migrator().migrate(pool)
        try store.recoverInterruptedMeetings()
        return store
    }

    /// テスト用のインメモリ DB。
    public static func inMemory() throws -> Store {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        let store = Store(writer: queue)
        try StoreSchema.migrator().migrate(queue)
        return store
    }

    init(writer: any DatabaseWriter, leaseDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-locks-" + UUID().uuidString)) {
        self.writer = writer
        self.leaseDirectory = leaseDirectory
    }

    public func acquireMeetingLease(_ meetingId: String) throws -> MeetingLease {
        try MeetingLease(directory: leaseDirectory, meetingId: meetingId)
    }

    func validateMeetingLease(_ lease: MeetingLease, meetingId: String) throws {
        guard lease.meetingId == meetingId, lease.directory == leaseDirectory else { throw StoreError.meetingBusy(meetingId) }
    }

    /// ファイルロックを取れる会議だけ中断扱いにする。成功済みステップと音声は残す。
    @discardableResult
    public func recoverInterruptedMeetings() throws -> [String] {
        let ids = try writer.read { db in
            try String.fetchAll(db, sql: """
            SELECT id FROM meetings WHERE status IN ('recording', 'finalizing')
            UNION SELECT meeting_id FROM pipeline_runs WHERE status = 'running'
            UNION SELECT meeting_id FROM post_processing_jobs WHERE status = 'running'
            """)
        }
        var recovered: [String] = []
        for id in ids {
            let lease: MeetingLease
            do { lease = try acquireMeetingLease(id) }
            catch StoreError.meetingBusy { continue }
            try withExtendedLifetime(lease) {
                try writer.write { db in
                    if let job = try PostProcessingJob.fetchOne(db, key: id), job.jobStatus != .failed {
                        if try MeetingRecord.fetchOne(db, key: id)?.meetingStatus == .done {
                            // パイプライン完了後、ジョブ削除前に終了した。API を再実行しない。
                            try db.execute(sql: "DELETE FROM post_processing_jobs WHERE meeting_id = ?", arguments: [id])
                        } else {
                            try db.execute(sql: "UPDATE pipeline_runs SET status = 'failed', finished_at = ?, error = '後処理が中断されました。再開します' WHERE meeting_id = ? AND status = 'running'", arguments: [Store.isoString(Date()), id])
                            try db.execute(sql: "UPDATE post_processing_jobs SET status = 'queued', started_at = NULL, error = NULL WHERE meeting_id = ?", arguments: [id])
                            try db.execute(sql: "UPDATE meetings SET status = 'finalizing', updated_at = ? WHERE id = ?", arguments: [Store.isoString(Date()), id])
                        }
                        return
                    }
                    try db.execute(sql: "UPDATE pipeline_runs SET status = 'failed', finished_at = ?, error = '処理が中断されました。再実行できます' WHERE meeting_id = ? AND status = 'running'", arguments: [Store.isoString(Date()), id])
                    try db.execute(sql: "INSERT INTO pipeline_runs(meeting_id, step, status, started_at, finished_at, error) SELECT id, 'recovery', 'failed', ?, ?, '前回の録音・処理が中断されました。保存済み音声から再実行できます' FROM meetings WHERE id = ? AND status IN ('recording', 'finalizing')", arguments: [Store.isoString(Date()), Store.isoString(Date()), id])
                    try db.execute(sql: "UPDATE meetings SET status = 'failed', ended_at = COALESCE(ended_at, updated_at), updated_at = ? WHERE id = ? AND status IN ('recording', 'finalizing')", arguments: [Store.isoString(Date()), id])
                }
            }
            recovered.append(id)
        }
        return recovered
    }

    /// 先に下流の成功記録を無効化するため、途中で終了しても古い成功結果を再利用しない。
    public func invalidateRuns(meetingId: String, steps: [PipelineStep]) throws {
        try writer.write { db in
            for step in steps {
                var record = PipelineRunRecord(meetingId: meetingId, step: step.rawValue, status: .invalidated, finishedAt: Date(), error: "入力変更により再実行が必要")
                try record.insert(db)
            }
        }
    }

    public func claimAutoRecording(occurrence: String, expiresAt: Date, now: Date) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM auto_record_attempts WHERE expires_at < ?", arguments: [Store.isoString(now)])
            try db.execute(sql: "INSERT OR IGNORE INTO auto_record_attempts VALUES (?, ?)", arguments: [occurrence, Store.isoString(expiresAt)])
            return db.changesCount == 1
        }
    }


    // MARK: - Dates

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// SQL 比較用の ISO 8601（UTC）文字列。レコードの日時列と同じ形式。
    public static func isoString(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    // MARK: - Meetings

    @discardableResult
    public func createMeeting(_ meeting: MeetingRecord) throws -> MeetingRecord {
        var record = meeting
        record.createdAt = Date()
        record.updatedAt = record.createdAt
        try writer.write { db in try record.insert(db) }
        return record
    }

    public func meeting(id: String) throws -> MeetingRecord? {
        try writer.read { db in try MeetingRecord.fetchOne(db, key: id) }
    }

    public func updateMeeting(_ meeting: MeetingRecord) throws {
        var record = meeting
        record.updatedAt = Date()
        try writer.write { db in try record.update(db) }
    }

    public func clearAudioDirectory(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE meetings SET audio_dir = NULL, updated_at = ? WHERE id = ?", arguments: [Store.isoString(Date()), id])
        }
    }

    public func updateMeetingMetadata(id: String, title: String?, privacy: PrivacyMode?) throws {
        try writer.write { db in
            guard var current = try MeetingRecord.fetchOne(db, key: id) else { throw StoreError.notFound(id) }
            if let title { current.title = title }
            if let privacy { current.privacy = privacy }
            current.updatedAt = Date()
            try current.update(db)
        }
    }

    public func setPrivacyMode(id: String, mode: PrivacyMode) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE meetings SET privacy_mode = ?, updated_at = ? WHERE id = ?", arguments: [mode.rawValue, Store.isoString(Date()), id])
        }
    }

    /// 会議の開始時刻を音声検知・手動開始の時点に合わせる。録音原点（`recording_started_at`）は動かさない。
    public func setMeetingStarted(id: String, at startedAt: Date) throws {
        try writer.write { db in
            guard var record = try MeetingRecord.fetchOne(db, key: id) else { throw StoreError.notFound("meeting \(id)") }
            if record.recordingStartedAt == nil { record.recordingStartedAt = record.startedAt }
            record.startedAt = max(startedAt, record.recordingStartedAt ?? startedAt)
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    public func updateMeetingTitle(id: String, title: String) throws {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw StoreError.notFound("タイトル") }
        try updateMeetingMetadata(id: id, title: cleaned, privacy: nil)
    }

    public func updateMeetingAttendees(id: String, attendees: [Attendee]) throws {
        try writer.write { db in
            guard var current = try MeetingRecord.fetchOne(db, key: id) else { throw StoreError.notFound(id) }
            current.attendees = attendees
            current.updatedAt = Date()
            try current.update(db)
        }
    }

    public func setMeetingStatus(id: String, status: MeetingStatus, endedAt: Date? = nil) throws {
        try writer.write { db in
            guard var record = try MeetingRecord.fetchOne(db, key: id) else { throw StoreError.notFound("meeting \(id)") }
            record.meetingStatus = status
            if let endedAt { record.endedAt = endedAt }
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    public func listMeetings(_ filter: MeetingFilter = .all, limit: Int = 500) throws -> [MeetingRecord] {
        try writer.read { db in try Store.fetchMeetings(db, filter: filter, limit: limit) }
    }

    static func fetchMeetings(_ db: Database, filter: MeetingFilter, limit: Int) throws -> [MeetingRecord] {
        var request = MeetingRecord.order(Column("started_at").desc).limit(limit)
        let calendar = Calendar.current
        switch filter {
        case .all:
            break
        case .today:
            let start = calendar.startOfDay(for: Date())
            request = request.filter(Column("started_at") >= isoString(start))
        case .thisWeek:
            let now = Date()
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            request = request.filter(Column("started_at") >= isoString(start))
        case .unprocessed:
            request = request.filter(Column("status") != MeetingStatus.done.rawValue)
        case .processing:
            request = request.filter([MeetingStatus.recording.rawValue, MeetingStatus.finalizing.rawValue].contains(Column("status")))
        case let .status(status):
            request = request.filter(Column("status") == status.rawValue)
        case let .tag(tag):
            request = request.filter(sql: "EXISTS (SELECT 1 FROM json_each(meetings.tags_json) WHERE json_each.value = ?)", arguments: [tag])
        case let .since(date):
            request = request.filter(Column("started_at") >= isoString(date))
        }
        return try request.fetchAll(db)
    }

    // MARK: - Tags

    public func setMeetingTags(id: String, tags: [String]) throws {
        try writer.write { db in
            guard var current = try MeetingRecord.fetchOne(db, key: id) else { throw StoreError.notFound(id) }
            current.tags = tags
            current.updatedAt = Date()
            try current.update(db)
        }
    }

    /// 全会議のタグと件数（名前順）。
    public func tagCounts() throws -> [TagCount] {
        try writer.read { db in try Store.fetchTagCounts(db) }
    }

    static func fetchTagCounts(_ db: Database) throws -> [TagCount] {
        try Row.fetchAll(db, sql: """
            SELECT json_each.value AS tag, COUNT(*) AS count FROM meetings, json_each(meetings.tags_json)
            WHERE meetings.tags_json IS NOT NULL GROUP BY json_each.value ORDER BY json_each.value
            """).map { TagCount(tag: $0["tag"], count: $0["count"]) }
    }

    public func tagsObservation() -> ValueObservation<ValueReducers.Fetch<[TagCount]>> {
        ValueObservation.tracking { db in try Store.fetchTagCounts(db) }
    }

    /// UI 用: 会議一覧の変化を監視する。
    public func meetingsObservation(_ filter: MeetingFilter = .all, limit: Int = 500) -> ValueObservation<ValueReducers.Fetch<[MeetingRecord]>> {
        ValueObservation.tracking { db in try Store.fetchMeetings(db, filter: filter, limit: limit) }
    }

    /// 会議一覧と要約の 1 行目（一覧の副題用）をまとめて監視する。
    public func meetingListObservation(_ filter: MeetingFilter = .all, limit: Int = 500) -> ValueObservation<ValueReducers.Fetch<MeetingListSnapshot>> {
        ValueObservation.tracking { db in
            let meetings = try Store.fetchMeetings(db, filter: filter, limit: limit)
            return MeetingListSnapshot(meetings: meetings, previews: try Store.fetchSummaryPreviews(db, meetingIds: meetings.map(\.id)))
        }
    }

    static func fetchSummaryPreviews(_ db: Database, meetingIds: [String]) throws -> [String: String] {
        guard !meetingIds.isEmpty else { return [:] }
        var previews: [String: String] = [:]
        let rows = try Row.fetchAll(db, sql: "SELECT meeting_id, summary_md FROM notes WHERE summary_md IS NOT NULL AND meeting_id IN (\(databaseQuestionMarks(count: meetingIds.count)))", arguments: StatementArguments(meetingIds))
        for row in rows {
            let markdown: String = row["summary_md"]
            if let preview = Store.summaryPreview(markdown) { previews[row["meeting_id"]] = preview }
        }
        return previews
    }

    /// 見出しではない最初の文（箇条書き記号・強調を落とす）。本文がなければ最初の見出し。
    static func summaryPreview(_ markdown: String, limit: Int = 120) -> String? {
        var heading: String?
        for rawLine in markdown.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            let isHeading = line.hasPrefix("#")
            while let first = line.first, "#-*>".contains(first) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) { line.removeSubrange(range) }
            line = line.replacingOccurrences(of: "**", with: "")
            guard !line.isEmpty else { continue }
            if isHeading {
                if heading == nil { heading = line }
                continue
            }
            return line.count > limit ? String(line.prefix(limit)) + "…" : line
        }
        return heading.map { $0.count > limit ? String($0.prefix(limit)) + "…" : $0 }
    }

    public func deleteMeeting(id: String) throws {
        let lease = try acquireMeetingLease(id)
        try performMeetingDeletion(id: id, lease: lease)
    }

    /// armed のキャンセル専用。録音の teardown 完了後、所有中のロックを引き継いで削除する。
    func discardStoppedRecording(id: String, lease: MeetingLease) throws {
        try performMeetingDeletion(id: id, lease: lease, allowStoppedRecording: true)
    }

    func performMeetingDeletion(id: String, lease: MeetingLease, allowStoppedRecording: Bool = false,
                                removeDirectory: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        try validateMeetingLease(lease, meetingId: id)
        defer { withExtendedLifetime(lease) {} }
        try writer.write { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: id) else { return }
            guard allowStoppedRecording || (meeting.meetingStatus != .recording && meeting.meetingStatus != .finalizing) else {
                throw StoreError.meetingBusy(id)
            }
            if let directory = meeting.audioDir {
                // DB の削除と同一トランザクションで記録。commit 失敗時は音声に触れない。
                try db.execute(sql: "INSERT OR REPLACE INTO pending_audio_deletions(meeting_id, audio_dir) VALUES (?, ?)", arguments: [id, directory])
            }
            _ = try MeetingRecord.deleteOne(db, key: id)
            try db.execute(sql: "DELETE FROM notes_fts WHERE meeting_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM pipeline_runs WHERE meeting_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM export_log WHERE meeting_id = ?", arguments: [id])
        }
        try removePendingAudio(id: id, removeDirectory: removeDirectory)
    }

    private func removePendingAudio(id: String, removeDirectory: (URL) throws -> Void) throws {
        guard let path = try writer.read({ db in
            try String.fetchOne(db, sql: "SELECT audio_dir FROM pending_audio_deletions WHERE meeting_id = ?", arguments: [id])
        }) else { return }
        do {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { try removeDirectory(url) }
            try writer.write { db in
                try db.execute(sql: "DELETE FROM pending_audio_deletions WHERE meeting_id = ?", arguments: [id])
            }
        } catch { throw StoreError.audioDeletionPending(error.localizedDescription) }
    }

    /// 削除済み会議の音声清掃を再開する。ファイル削除失敗やプロセス終了でも依頼を失わない。
    public func retryPendingAudioDeletions() throws -> [String] {
        let ids = try writer.read { db in try String.fetchAll(db, sql: "SELECT meeting_id FROM pending_audio_deletions") }
        var errors: [String] = []
        for id in ids {
            do {
                let lease = try acquireMeetingLease(id)
                defer { withExtendedLifetime(lease) {} }
                guard try meeting(id: id) == nil else { continue }
                try removePendingAudio(id: id) { try FileManager.default.removeItem(at: $0) }
            } catch StoreError.meetingBusy { continue }
            catch { errors.append(error.localizedDescription) }
        }
        return errors
    }

    // MARK: - Segments

    @discardableResult
    public func appendSegments(_ segments: [SegmentRecord]) throws -> [SegmentRecord] {
        guard !segments.isEmpty else { return [] }
        return try writer.write { db in
            var inserted: [SegmentRecord] = []
            for var segment in segments {
                try segment.insert(db)
                inserted.append(segment)
            }
            return inserted
        }
    }

    /// raw の世代は残し、人間の編集がある確定本文は自動再認識で置き換えない。
    /// 同一の発話は ID を再利用する。消えた発話も旧リンク用に残す。
    @discardableResult
    public func replaceSegments(meetingId: String, source: SegmentSource, with segments: [SegmentRecord]) throws -> [SegmentRecord] {
        try writer.write { db in try Store.reconcileSegments(db, meetingId: meetingId, source: source, segments: segments) }
    }

    static func reconcileSegments(_ db: Database, meetingId: String, source: SegmentSource, segments: [SegmentRecord]) throws -> [SegmentRecord] {
        let current = try fetchSegments(db, meetingId: meetingId, source: source)
        let content = String(decoding: try JSONCoding.encoder().encode(segments.map { record -> SegmentRecord in
            var raw = record; raw.id = nil; raw.speakerId = nil; return raw
        }), as: UTF8.self)
        if source == .final {
            try db.execute(sql: "INSERT OR IGNORE INTO transcript_revisions(meeting_id, content, created_at) VALUES (?, ?, ?)", arguments: [meetingId, content, Store.isoString(Date())])
            // 境界変更を推測でマッピングすると編集内容や根拠が別発話へ移るため、編集済み世代を維持する。
            if current.contains(where: { $0.originalText == nil || $0.text != $0.originalText }) { return current }
        }
        try db.execute(sql: "UPDATE segments SET is_current = 0 WHERE meeting_id = ? AND source = ?", arguments: [meetingId, source.rawValue])
        var unused = current
        var result: [SegmentRecord] = []
        for var incoming in segments {
            if let index = unused.firstIndex(where: {
                $0.tStart == incoming.tStart && $0.tEnd == incoming.tEnd && $0.clusterLabel == incoming.clusterLabel && ($0.originalText ?? $0.text) == incoming.text
            }) {
                incoming = unused.remove(at: index)
                incoming.isCurrent = true
                try incoming.update(db)
            } else {
                incoming.id = nil
                incoming.meetingId = meetingId
                incoming.source = source.rawValue
                incoming.originalText = incoming.text
                incoming.isCurrent = true
                try incoming.insert(db)
            }
            result.append(incoming)
        }
        return result
    }

    public func segment(id: Int64, meetingId: String) throws -> SegmentRecord? {
        try writer.read { db in try SegmentRecord.filter(Column("id") == id && Column("meeting_id") == meetingId).fetchOne(db) }
    }

    public func segments(meetingId: String, source: SegmentSource) throws -> [SegmentRecord] {
        try writer.read { db in try Store.fetchSegments(db, meetingId: meetingId, source: source) }
    }

    static func fetchSegments(_ db: Database, meetingId: String, source: SegmentSource) throws -> [SegmentRecord] {
        try SegmentRecord
            .filter(Column("meeting_id") == meetingId && Column("source") == source.rawValue && Column("is_current") == true)
            .order(Column("t_start"), Column("id"))
            .fetchAll(db)
    }

    /// final があれば final、なければ live。
    public func displaySegments(meetingId: String) throws -> (source: SegmentSource, segments: [SegmentRecord]) {
        try writer.read { db in
            let final = try Store.fetchSegments(db, meetingId: meetingId, source: .final)
            if !final.isEmpty { return (.final, final) }
            return (.live, try Store.fetchSegments(db, meetingId: meetingId, source: .live))
        }
    }

    public func segmentsObservation(meetingId: String) -> ValueObservation<ValueReducers.Fetch<(source: SegmentSource, segments: [SegmentRecord])>> {
        ValueObservation.tracking { db in
            let final = try Store.fetchSegments(db, meetingId: meetingId, source: .final)
            if !final.isEmpty { return (.final, final) }
            return (.live, try Store.fetchSegments(db, meetingId: meetingId, source: .live))
        }
    }

    public func updateSegmentText(id: Int64, text: String) throws {
        try writer.write { db in
            _ = try db.execute(sql: "UPDATE segments SET text = ? WHERE id = ?", arguments: [text, id])
        }
    }

    /// 1 発話だけ別の話者にする（話者分離の誤りの修正）。`speakerId` は同じ会議の speakers.id、nil で自動割当に戻す。
    /// クラスタ単位の再割当や再認識では、この個別指定を上書きしない。
    public func overrideSegmentSpeaker(segmentId: Int64, meetingId: String, speakerId: String?) throws {
        try writer.write { db in
            guard let segment = try SegmentRecord.filter(Column("id") == segmentId && Column("meeting_id") == meetingId).fetchOne(db) else { throw StoreError.notFound("発話 \(segmentId)") }
            let target: String?
            if let speakerId {
                guard try SpeakerRecord.filter(Column("id") == speakerId && Column("meeting_id") == meetingId).fetchOne(db) != nil else { throw StoreError.notFound("話者 \(speakerId)") }
                target = speakerId
            } else {
                target = try segment.clusterLabel.flatMap { try SpeakerRecord.filter(Column("meeting_id") == meetingId && Column("cluster_label") == $0).fetchOne(db)?.id }
            }
            try db.execute(sql: "UPDATE segments SET speaker_id = ? WHERE id = ?", arguments: [target, segmentId])
        }
    }

    /// 個別の発話を割り当てるための話者行を作る（クラスタを持たない）。同じ人物・名前があればそれを返す。
    @discardableResult
    public func findOrCreateManualSpeaker(meetingId: String, personId: String?, displayName: String) throws -> SpeakerRecord {
        try writer.write { db in
            let existing = try SpeakerRecord.filter(Column("meeting_id") == meetingId).fetchAll(db)
            if let personId, let found = existing.first(where: { $0.personId == personId }) { return found }
            if let found = existing.first(where: { $0.displayName == displayName }) { return found }
            let speaker = SpeakerRecord(meetingId: meetingId, clusterLabel: "manual_" + ULID.generate().suffix(8).lowercased(), personId: personId, displayName: displayName)
            try speaker.insert(db)
            return speaker
        }
    }

    public func deleteSegments(meetingId: String, source: SegmentSource) throws {
        try writer.write { db in
            _ = try SegmentRecord.filter(Column("meeting_id") == meetingId && Column("source") == source.rawValue).deleteAll(db)
        }
    }

    // MARK: - Speakers

    public func replaceSpeakers(meetingId: String, with speakers: [SpeakerRecord]) throws {
        try writer.write { db in try Store.saveSpeakers(db, meetingId: meetingId, speakers: speakers) }
    }

    static func saveSpeakers(_ db: Database, meetingId: String, speakers: [SpeakerRecord]) throws {
            let existing = try SpeakerRecord.filter(Column("meeting_id") == meetingId).fetchAll(db)
            let existingByLabel = Dictionary(uniqueKeysWithValues: existing.map { ($0.clusterLabel, $0) })
            for var speaker in speakers {
                speaker.meetingId = meetingId
                // 既に人間が割り当てていたら引き継ぐ（名前・背景の声の除外。音量は測り直すまで前の値）
                if let previous = existingByLabel[speaker.clusterLabel] {
                    speaker.id = previous.id
                    if speaker.personId == nil { speaker.personId = previous.personId }
                    if speaker.displayName == nil { speaker.displayName = previous.displayName }
                    if speaker.levelDb == nil { speaker.levelDb = previous.levelDb }
                    speaker.excluded = speaker.excluded || previous.excluded
                }
                try speaker.save(db)
            }
            // segments.speaker_id をクラスタラベルから張り直す（発話単位の個別指定は残す）
            for speaker in try SpeakerRecord.filter(Column("meeting_id") == meetingId).fetchAll(db) {
                try Store.relinkSegments(db, meetingId: meetingId, clusterLabel: speaker.clusterLabel, speakerId: speaker.id)
            }
    }

    /// クラスタの発話をその話者に結び付ける。別の話者へ個別に変更済みの発話（同じ会議の有効な speakers.id を指す）は触らない。
    static func relinkSegments(_ db: Database, meetingId: String, clusterLabel: String, speakerId: String) throws {
        try db.execute(
            sql: """
            UPDATE segments SET speaker_id = ? WHERE meeting_id = ? AND cluster_label = ?
              AND (speaker_id IS NULL OR speaker_id = ? OR speaker_id NOT IN (SELECT id FROM speakers WHERE meeting_id = ?))
            """,
            arguments: [speakerId, meetingId, clusterLabel, speakerId, meetingId]
        )
    }

    public func saveTranscript(meetingId: String, segments: [SegmentRecord], speakers: [SpeakerRecord]) throws {
        try writer.write { db in
            _ = try Store.reconcileSegments(db, meetingId: meetingId, source: .final, segments: segments)
            try Store.saveSpeakers(db, meetingId: meetingId, speakers: speakers)
        }
    }

    public func speakers(meetingId: String) throws -> [SpeakerRecord] {
        try writer.read { db in try Store.fetchSpeakers(db, meetingId: meetingId) }
    }

    static func fetchSpeakers(_ db: Database, meetingId: String) throws -> [SpeakerRecord] {
        try SpeakerRecord.filter(Column("meeting_id") == meetingId).order(Column("cluster_label")).fetchAll(db)
    }

    public func speakersObservation(meetingId: String) -> ValueObservation<ValueReducers.Fetch<[SpeakerRecord]>> {
        ValueObservation.tracking { db in try Store.fetchSpeakers(db, meetingId: meetingId) }
    }

    /// 相手側の話者の音量を保存する（クラスタラベル → dBFS、`BackgroundVoices`）。測れなかった話者は nil に戻す。
    public func setSpeakerLevels(meetingId: String, levels: [String: Double]) throws {
        try writer.write { db in
            for var speaker in try SpeakerRecord.filter(Column("meeting_id") == meetingId).fetchAll(db) {
                let level = levels[speaker.clusterLabel]
                guard speaker.levelDb != level else { continue }
                speaker.levelDb = level
                try speaker.update(db)
            }
        }
    }

    /// 話者を背景の声として除外する（`excluded == false` で戻す）。発話は消さず、本文では折りたたみ、要約・書き出し・検索から外す。
    public func setSpeakerExcluded(meetingId: String, speakerId: String, excluded: Bool) throws {
        try writer.write { db in
            guard var speaker = try SpeakerRecord.filter(Column("id") == speakerId && Column("meeting_id") == meetingId).fetchOne(db) else { throw StoreError.notFound("話者 \(speakerId)") }
            guard speaker.excluded != excluded else { return }
            speaker.excluded = excluded
            try speaker.update(db)
        }
    }

    /// 話者クラスタに人を割り当てる（SPEC §5.4 の 3、§10.2）。同クラスタ全体に反映する。
    public func assignSpeaker(meetingId: String, clusterLabel: String, personId: String?, displayName: String?) throws {
        try writer.write { db in
            if var speaker = try SpeakerRecord.filter(Column("meeting_id") == meetingId && Column("cluster_label") == clusterLabel).fetchOne(db) {
                speaker.personId = personId
                speaker.displayName = displayName
                try speaker.update(db)
                try Store.relinkSegments(db, meetingId: meetingId, clusterLabel: clusterLabel, speakerId: speaker.id)
            } else {
                let speaker = SpeakerRecord(meetingId: meetingId, clusterLabel: clusterLabel, personId: personId, displayName: displayName)
                try speaker.insert(db)
                try Store.relinkSegments(db, meetingId: meetingId, clusterLabel: clusterLabel, speakerId: speaker.id)
            }
        }
    }

    // MARK: - People

    @discardableResult
    public func upsertPerson(_ person: PersonRecord) throws -> PersonRecord {
        try writer.write { db in
            try person.save(db)
            return person
        }
    }

    public func people() throws -> [PersonRecord] {
        try writer.read { db in try PersonRecord.order(Column("name")).fetchAll(db) }
    }

    public func person(id: String) throws -> PersonRecord? {
        try writer.read { db in try PersonRecord.fetchOne(db, key: id) }
    }

    public func person(email: String) throws -> PersonRecord? {
        try writer.read { db in try PersonRecord.filter(Column("email") == email.lowercased()).fetchOne(db) }
    }

    /// 参加者から people を作る/引く（メール一致 → 名前一致）。
    @discardableResult
    public func findOrCreatePerson(name: String, email: String?) throws -> PersonRecord {
        try writer.write { db in
            if let email, let found = try PersonRecord.filter(Column("email") == email.lowercased()).fetchOne(db) { return found }
            if let found = try PersonRecord.filter(Column("name") == name).fetchOne(db) { return found }
            let person = PersonRecord(name: name, email: email?.lowercased())
            try person.insert(db)
            return person
        }
    }

    public func addVoiceSample(personId: String, sample: VoiceSample) throws {
        try writer.write { db in
            guard var person = try PersonRecord.fetchOne(db, key: personId) else { throw StoreError.notFound("person \(personId)") }
            person.voiceSamples.append(sample)
            try person.update(db)
        }
    }

    public func renamePerson(id: String, name: String) throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw StoreError.notFound("名前") }
        try writer.write { db in
            guard var person = try PersonRecord.fetchOne(db, key: id) else { throw StoreError.notFound("person \(id)") }
            person.name = cleaned
            try person.update(db)
            // 会議側の表示名も追従させる
            try db.execute(sql: "UPDATE speakers SET display_name = ? WHERE person_id = ?", arguments: [cleaned, id])
        }
    }

    /// 人物を削除する。話者の割当は名前だけ残し（person_id は NULL）、声のサンプルのパスを返すので呼び出し側でファイルを消す。
    @discardableResult
    public func deletePerson(id: String) throws -> [String] {
        try writer.write { db in
            guard let person = try PersonRecord.fetchOne(db, key: id) else { return [] }
            let paths = person.voiceSamples.map(\.path)
            _ = try PersonRecord.deleteOne(db, key: id)
            return paths
        }
    }

    /// 重複した人物を統合する。`duplicateId` の話者割当・サンプルを `primaryId` へ移す。
    public func mergePeople(primaryId: String, duplicateId: String) throws -> [String] {
        guard primaryId != duplicateId else { return [] }
        return try writer.write { db in
            guard var primary = try PersonRecord.fetchOne(db, key: primaryId), let duplicate = try PersonRecord.fetchOne(db, key: duplicateId) else { throw StoreError.notFound("person") }
            primary.voiceSamples += duplicate.voiceSamples
            if primary.email == nil { primary.email = duplicate.email }
            var aliases = primary.aliases
            if duplicate.name != primary.name, !aliases.contains(duplicate.name) { aliases.append(duplicate.name) }
            primary.aliases = aliases
            try primary.update(db)
            try db.execute(sql: "UPDATE speakers SET person_id = ?, display_name = ? WHERE person_id = ?", arguments: [primaryId, primary.name, duplicateId])
            _ = try PersonRecord.deleteOne(db, key: duplicateId)
            return duplicate.voiceSamples.map(\.path)
        }
    }

    // MARK: - Notes

    /// ユーザーメモと完了チェックは生成結果の保存と同じトランザクションで引き継ぐ。
    public func summaryInput(meetingId: String) throws -> SummaryInput {
        try writer.read { db in try Store.fetchSummaryInput(db, meetingId: meetingId) }
    }

    static func fetchSummaryInput(_ db: Database, meetingId: String) throws -> SummaryInput {
        guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { throw StoreError.notFound(meetingId) }
        let speakers = try fetchSpeakers(db, meetingId: meetingId)
        // 除外した話者（背景の声）の発話と名前は渡さない
        let records = BackgroundVoices.removingExcluded(try fetchSegments(db, meetingId: meetingId, source: .final), speakers: speakers)
        let names = Dictionary(uniqueKeysWithValues: speakers.filter { !$0.excluded }.map { ($0.clusterLabel, $0.label) })
        let byId = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        return SummaryInput(meetingTitle: meeting.title, startedAt: meeting.startedAt, attendees: meeting.attendees, segments: records.compactMap { row in
            guard let id = row.id else { return nil }
            // 発話単位で話者を変更していれば、その話者のラベルで要約に渡す
            let label = row.speakerId.flatMap { byId[$0]?.clusterLabel } ?? row.clusterLabel
            return TranscriptDocument.Segment(id: Int(id), track: label == "me" ? "mic" : "system", tStart: row.tStart, tEnd: row.tEnd, speaker: label, text: row.text)
        }, speakerNames: names)
    }

    public func saveGeneratedSummary(meetingId: String, summary: MinutesSummary, model: String, inputFingerprint: String) throws {
        try writer.write { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId), meeting.privacy == .cloudOk else { throw PipelineError.summaryUnavailable }
            guard try PipelineFingerprint.encoded(Store.fetchSummaryInput(db, meetingId: meetingId)) == inputFingerprint else { throw PipelineError.staleSummary }
            let existing = try NotesRecord.fetchOne(db, key: meetingId)
            let previous = existing?.actionItems ?? []
            var preserved = summary
            // 生成結果には ID がないので、内容が同じ既存アクションから ID と完了状態を引き継ぐ。残りは採番する。
            var unmatched = previous.filter { $0.manual != true }
            for index in preserved.actionItems.indices {
                let action = preserved.actionItems[index]
                if let found = unmatched.firstIndex(where: { $0.matchesContent(of: action) }) {
                    let match = unmatched.remove(at: found)
                    preserved.actionItems[index].done = match.done
                    preserved.actionItems[index].id = match.id ?? UUID().uuidString.lowercased()
                } else {
                    preserved.actionItems[index].id = UUID().uuidString.lowercased()
                }
                preserved.actionItems[index].manual = nil
            }
            // 人が追加したアクションは再要約で消さない
            preserved.actionItems += previous.filter { $0.manual == true }
            let notes = NotesRecord(meetingId: meetingId, summary: preserved, model: model, userNotesMd: existing?.userNotesMd, inputFingerprint: inputFingerprint)
            try notes.save(db)
            try Store.refreshNotesFTS(db, notes: notes)
        }
    }

    /// 手動でアクションを追加する（要約がなくても可）。
    @discardableResult
    public func addManualAction(meetingId: String, text: String, owner: String = "me", kind: MinutesSummary.ActionKind = .ownCommitment, due: String? = nil) throws -> NotesRecord {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw StoreError.notFound("アクションの本文") }
        return try writer.write { db in
            var notes = try NotesRecord.fetchOne(db, key: meetingId) ?? NotesRecord(meetingId: meetingId)
            var items = notes.actionItems
            items.append(.init(text: cleaned, owner: owner, kind: kind, due: due, evidence: [], done: false, id: UUID().uuidString.lowercased(), manual: true))
            notes.setActionItems(items)
            try notes.save(db)
            try Store.refreshNotesFTS(db, notes: notes)
            return notes
        }
    }

    @discardableResult
    public func updateAction(meetingId: String, actionId: String, text: String? = nil, owner: String? = nil, kind: MinutesSummary.ActionKind? = nil, due: String?? = nil) throws -> NotesRecord {
        try writer.write { db in
            guard var notes = try NotesRecord.fetchOne(db, key: meetingId) else { throw StoreError.notFound("アクション") }
            var items = notes.actionItems
            guard let index = items.firstIndex(where: { $0.id == actionId }) else { throw StoreError.notFound("アクション \(actionId)") }
            if let text { items[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let owner { items[index].owner = owner }
            if let kind { items[index].kind = kind }
            if let due { items[index].due = due }
            notes.setActionItems(items)
            try notes.save(db)
            try Store.refreshNotesFTS(db, notes: notes)
            return notes
        }
    }

    @discardableResult
    public func removeAction(meetingId: String, actionId: String) throws -> NotesRecord {
        try writer.write { db in
            guard var notes = try NotesRecord.fetchOne(db, key: meetingId) else { throw StoreError.notFound("アクション") }
            notes.setActionItems(notes.actionItems.filter { $0.id != actionId })
            try notes.save(db)
            try Store.refreshNotesFTS(db, notes: notes)
            return notes
        }
    }

    public func upsertNotes(_ notes: NotesRecord) throws {
        try writer.write { db in
            try notes.save(db)
            try Store.refreshNotesFTS(db, notes: notes)
        }
    }

    static func refreshNotesFTS(_ db: Database, notes: NotesRecord) throws {
        try db.execute(sql: "DELETE FROM notes_fts WHERE meeting_id = ?", arguments: [notes.meetingId])
        let body = [
            notes.summaryMd,
            notes.decisions.map(\.text).joined(separator: "\n"),
            notes.actionItems.map(\.text).joined(separator: "\n"),
            notes.openQuestions.map(\.text).joined(separator: "\n"),
            notes.userNotesMd,
        ].compactMap { $0 }.joined(separator: "\n")
        try db.execute(sql: "INSERT INTO notes_fts(meeting_id, body) VALUES (?, ?)", arguments: [notes.meetingId, body])
    }

    public func notes(meetingId: String) throws -> NotesRecord? {
        try writer.read { db in try NotesRecord.fetchOne(db, key: meetingId) }
    }

    public func notesObservation(meetingId: String) -> ValueObservation<ValueReducers.Fetch<NotesRecord?>> {
        ValueObservation.tracking { db in try NotesRecord.fetchOne(db, key: meetingId) }
    }

    public func updateUserNotes(meetingId: String, markdown: String) throws {
        try writer.write { db in
            var notes = try NotesRecord.fetchOne(db, key: meetingId) ?? NotesRecord(meetingId: meetingId)
            notes.userNotesMd = markdown
            try notes.save(db)
            try Store.refreshNotesFTS(db, notes: notes)
        }
    }

    /// View が保持する古い NotesRecord で、直近のメモ・要約を上書きしない。
    public func setActionCompletion(meetingId: String, action: MinutesSummary.ActionItem, done: Bool) throws -> NotesRecord {
        try writer.write { db in
            guard var notes = try NotesRecord.fetchOne(db, key: meetingId) else { throw StoreError.notFound("アクション") }
            var items = notes.actionItems
            let byId = action.id.flatMap { id in items.firstIndex { $0.id == id } }
            guard let index = byId ?? items.firstIndex(where: {
                $0.text == action.text && $0.owner == action.owner && $0.kind == action.kind
                    && $0.due == action.due && $0.evidence == action.evidence
            }) else { throw StoreError.notFound("更新前のアクション") }
            items[index].done = done
            notes.actionItemsJson = String(decoding: try JSONCoding.encoder(pretty: false).encode(items), as: UTF8.self)
            try notes.save(db)
            try Store.refreshNotesFTS(db, notes: notes)
            return notes
        }
    }

    // MARK: - Pipeline runs

    @discardableResult
    public func recordRun(meetingId: String, step: String, status: PipelineRunStatus, provider: String? = nil, startedAt: Date? = nil, error: String? = nil) throws -> PipelineRunRecord {
        var record = PipelineRunRecord(
            meetingId: meetingId, step: step, status: status, provider: provider,
            startedAt: startedAt ?? Date(), finishedAt: status == .running ? nil : Date(), error: error
        )
        try writer.write { db in try record.insert(db) }
        return record
    }

    public func finishRun(_ run: PipelineRunRecord, status: PipelineRunStatus, provider: String? = nil, error: String? = nil, fingerprint: String? = nil) throws {
        var record = run
        record.status = status.rawValue
        record.finishedAt = Date()
        if let provider { record.provider = provider }
        record.error = error
        record.fingerprint = fingerprint
        try writer.write { db in try record.update(db) }
    }

    public func latestRun(meetingId: String, step: String) throws -> PipelineRunRecord? {
        try writer.read { db in
            try PipelineRunRecord.filter(Column("meeting_id") == meetingId && Column("step") == step).order(Column("id").desc).fetchOne(db)
        }
    }

    public func runs(meetingId: String) throws -> [PipelineRunRecord] {
        try writer.read { db in
            try PipelineRunRecord.filter(Column("meeting_id") == meetingId).order(Column("id")).fetchAll(db)
        }
    }

    // MARK: - Export log

    /// 同期フォルダへのローカル書き込みも送信に相当する。書き込みが終わるまで privacy の更新を直列化する。
    public func withCloudExport<T>(meetingId: String, _ write: (MeetingExporter.Input) throws -> T) throws -> T {
        try writer.write { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { throw StoreError.notFound(meetingId) }
            guard meeting.privacy == .cloudOk else { throw PipelineError.localOnlyExport }
            let final = try Store.fetchSegments(db, meetingId: meetingId, source: .final)
            let segments = final.isEmpty ? try Store.fetchSegments(db, meetingId: meetingId, source: .live) : final
            let speakers = try Store.fetchSpeakers(db, meetingId: meetingId)
            let notes = try NotesRecord.fetchOne(db, key: meetingId)
            let provider = try PipelineRunRecord.filter(Column("meeting_id") == meetingId && Column("step") == PipelineStep.transcribeFinal.rawValue)
                .order(Column("id").desc).fetchOne(db)?.provider ?? (final.isEmpty ? "live" : "unknown")
            return try write(.init(meeting: meeting, speakers: speakers, segments: segments, notes: notes, providerDescription: provider))
        }
    }

    @discardableResult
    public func logExport(meetingId: String, target: String, status: ExportStatus, checksum: String? = nil) throws -> ExportLogRecord {
        var record = ExportLogRecord(meetingId: meetingId, target: target, checksum: checksum, status: status)
        try writer.write { db in try record.insert(db) }
        return record
    }

    /// target ごとの最新ログが pending のもの（再送対象）。
    public func pendingExports() throws -> [ExportLogRecord] {
        try writer.read { db in
            try ExportLogRecord.fetchAll(db, sql: """
            SELECT e.* FROM export_log e
            WHERE e.id = (SELECT MAX(id) FROM export_log WHERE meeting_id = e.meeting_id AND target = e.target)
              AND e.status = 'pending'
            ORDER BY e.id
            """)
        }
    }

    public func exportLog(meetingId: String) throws -> [ExportLogRecord] {
        try writer.read { db in
            try ExportLogRecord.filter(Column("meeting_id") == meetingId).order(Column("id")).fetchAll(db)
        }
    }

    public func hasSuccessfulExport(meetingId: String) throws -> Bool {
        try writer.read { db in
            try ExportLogRecord.filter(Column("meeting_id") == meetingId && Column("status") == ExportStatus.ok.rawValue).fetchCount(db) > 0
        }
    }

    // MARK: - Keyterms

    public func addKeyterms(_ terms: [String], source: String) throws {
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        try writer.write { db in
            for term in cleaned {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO keyterms(term, source, created_at) VALUES (?, ?, ?)",
                    arguments: [term, source, Store.isoString(Date())]
                )
            }
        }
    }

    /// 送信上限（1000 語）で打ち切られても新しい語が残るよう、新しい順に返す。
    public func keyterms() throws -> [String] {
        try writer.read { db in try String.fetchAll(db, sql: "SELECT term FROM keyterms ORDER BY created_at DESC, term") }
    }

    public func keytermRecords() throws -> [KeytermRecord] {
        try writer.read { db in try KeytermRecord.order(Column("created_at").desc, Column("term")).fetchAll(db) }
    }

    public func manualKeyterms() throws -> [String] {
        try writer.read { db in try String.fetchAll(db, sql: "SELECT term FROM keyterms WHERE source != 'learned' ORDER BY term") }
    }

    public func removeKeyterm(_ term: String) throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM keyterms WHERE term = ?", arguments: [term]) }
    }

    // MARK: - Search (SPEC §7.2)

    /// 本文（FTS5 trigram、3 文字未満は LIKE）・要約/メモ・タイトル/参加者を検索し、会議単位（新しい順）にまとめる。
    /// - Parameters:
    ///   - meetingLimit: 返す会議数の上限。
    ///   - hitsPerMeeting: 会議ごとに返す発話ヒットの上限（時刻順）。
    public func search(_ rawQuery: String, meetingLimit: Int = 50, hitsPerMeeting: Int = 20) throws -> [SearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return try writer.read { db in
            let pattern = "%" + Store.escapeLike(query) + "%"
            let notExcluded = try Store.notExcludedCondition(db, segment: "s")
            // 会議の新しい順に、ヒットした発話をまとめて取る（is_current のみ。背景の声として除外した話者の発話は除く）。
            let hitSQL: String
            let hitArguments: StatementArguments
            if query.count < 3 {
                // trigram は 3 文字未満にヒットしないので LIKE にフォールバック
                hitSQL = """
                SELECT s.* FROM segments s JOIN meetings m ON m.id = s.meeting_id
                WHERE s.is_current = 1 AND s.text LIKE ? ESCAPE '\\'\(notExcluded)
                ORDER BY m.started_at DESC, s.t_start, s.id LIMIT ?
                """
                hitArguments = [pattern, meetingLimit * hitsPerMeeting * 4]
            } else {
                let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                hitSQL = """
                SELECT s.* FROM segments_fts f JOIN segments s ON s.id = f.rowid JOIN meetings m ON m.id = s.meeting_id
                WHERE segments_fts MATCH ? AND s.is_current = 1\(notExcluded)
                ORDER BY m.started_at DESC, s.t_start, s.id LIMIT ?
                """
                hitArguments = [phrase, meetingLimit * hitsPerMeeting * 4]
            }
            let hitSegments = try SegmentRecord.fetchAll(db, sql: hitSQL, arguments: hitArguments)
            let noteMeetingIds: [String]
            if query.count < 3 {
                noteMeetingIds = try String.fetchAll(db, sql: "SELECT meeting_id FROM notes_fts WHERE body LIKE ? ESCAPE '\\'", arguments: [pattern])
            } else {
                let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                noteMeetingIds = try String.fetchAll(db, sql: "SELECT meeting_id FROM notes_fts WHERE notes_fts MATCH ?", arguments: [phrase])
            }
            let titleMeetingIds = try String.fetchAll(db, sql: """
                SELECT id FROM meetings WHERE title LIKE ? ESCAPE '\\' OR calendar_title LIKE ? ESCAPE '\\' OR attendees_json LIKE ? ESCAPE '\\' OR tags_json LIKE ? ESCAPE '\\'
                ORDER BY started_at DESC LIMIT ?
                """, arguments: [pattern, pattern, pattern, pattern, meetingLimit])

            var meetingIds = Set(hitSegments.map(\.meetingId))
            meetingIds.formUnion(noteMeetingIds)
            meetingIds.formUnion(titleMeetingIds)
            let meetings = Array(try MeetingRecord.filter(keys: Array(meetingIds)).fetchAll(db)
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(meetingLimit))

            // 会議ごとに final 優先で上限まで選び、前後 1 件を 1 クエリでまとめて引く（前後にも除外した話者の発話は出さない）。
            var hitsByMeeting: [String: [SegmentRecord]] = [:]
            for meeting in meetings {
                let all = hitSegments.filter { $0.meetingId == meeting.id }
                let preferred = all.contains { $0.source == SegmentSource.final.rawValue } ? SegmentSource.final.rawValue : SegmentSource.live.rawValue
                hitsByMeeting[meeting.id] = Array(all.filter { $0.source == preferred }.prefix(hitsPerMeeting))
            }
            let selected = hitsByMeeting.values.flatMap { $0 }
            var neighbours: [Int64: (previous: Int64?, next: Int64?)] = [:]
            if !selected.isEmpty {
                let ids = selected.compactMap(\.id)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, prev_id, next_id FROM (
                      SELECT s.id AS id,
                             LAG(s.id) OVER w AS prev_id,
                             LEAD(s.id) OVER w AS next_id
                      FROM segments s
                      WHERE s.is_current = 1 AND s.meeting_id IN (\(databaseQuestionMarks(count: meetings.count)))\(notExcluded)
                      WINDOW w AS (PARTITION BY s.meeting_id, s.source ORDER BY s.t_start, s.id)
                    ) WHERE id IN (\(databaseQuestionMarks(count: ids.count)))
                    """, arguments: StatementArguments(meetings.map(\.id)) + StatementArguments(ids))
                for row in rows { neighbours[row["id"]] = (row["prev_id"], row["next_id"]) }
            }
            let neighbourIds = neighbours.values.flatMap { [$0.previous, $0.next].compactMap { $0 } }
            let neighbourSegments = Dictionary(uniqueKeysWithValues: try SegmentRecord.filter(keys: neighbourIds).fetchAll(db).compactMap { record in record.id.map { ($0, record) } })

            return meetings.map { meeting in
                let hits = (hitsByMeeting[meeting.id] ?? []).map { hit -> SearchHit in
                    let around = hit.id.flatMap { neighbours[$0] }
                    let previous = around?.previous.flatMap { neighbourSegments[$0] }
                    let next = around?.next.flatMap { neighbourSegments[$0] }
                    return SearchHit(segment: hit, context: [previous, hit, next].compactMap { $0 })
                }
                return SearchResult(meeting: meeting, segmentHits: hits, notesMatched: noteMeetingIds.contains(meeting.id), titleMatched: titleMeetingIds.contains(meeting.id))
            }
        }
    }

    /// 背景の声として除外した話者の発話を外す条件（先頭の " AND " を含む）。除外した話者がいなければ空文字で、条件を付けない。`segment` は segments の別名。
    /// 話者の決め方は `SegmentRecord.speaker(in:)` と同じ（speaker_id を優先し、なければクラスタの話者）。speaker_id は同じ会議の
    /// 有効な話者しか指さない（再割当・個別変更で保証し、話者の行は会議ごとにしか消えない）。発話ごとに引くのは一度だけ作る話者 id の集合で、
    /// 相関副問い合わせは speaker_id がない発話（ライブ）だけ。発話ごとに副問い合わせを引く形では、100 会議の検索が 35〜60 ms 遅くなった。
    static func notExcludedCondition(_ db: Database, segment: String) throws -> String {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM speakers WHERE excluded = 1)") == true else { return "" }
        return """
         AND NOT ((\(segment).speaker_id IS NOT NULL AND \(segment).speaker_id IN (SELECT id FROM speakers WHERE excluded = 1))
          OR (\(segment).speaker_id IS NULL
              AND EXISTS (SELECT 1 FROM speakers ex WHERE ex.excluded = 1 AND ex.meeting_id = \(segment).meeting_id AND ex.cluster_label = \(segment).cluster_label)))
        """
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
