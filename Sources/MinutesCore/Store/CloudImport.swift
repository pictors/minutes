import Foundation
import GRDB

/// サーバーから取り込んだ録音の記録（SPEC §4.5）。会議を消しても残し、同じ録音を取り込み直さない。
/// 取り込めなかった録音は回数を覚えて、間をあけて試し直す。
public struct CloudImportRecord: MinutesRecord, Equatable {
    public static let databaseTableName = "cloud_imports"

    public enum Status: String, Sendable {
        case imported, failed
    }

    /// サーバーの録音の ID
    public var recordingId: String
    /// 作った会議（取り込めなかった録音は nil。会議を消しても消さない）
    public var meetingId: String?
    public var status: String
    /// 取り込めなかった回数
    public var attempts: Int
    public var attemptedAt: Date
    public var error: String?

    public init(recordingId: String, meetingId: String?, status: Status, attempts: Int, attemptedAt: Date, error: String?) {
        self.recordingId = recordingId
        self.meetingId = meetingId
        self.status = status.rawValue
        self.attempts = attempts
        self.attemptedAt = attemptedAt
        self.error = error
    }

    public var importStatus: Status { Status(rawValue: status) ?? .failed }

    /// 取り込めなかった録音を次に試してよい時刻。
    public var retryAt: Date { attemptedAt.addingTimeInterval(CloudImportRecord.retryDelay(attempts: attempts)) }

    /// 試し直すまでの間: 10 分から倍々に延ばし、最長 1 日（壊れた録音を 10 分ごとの定期処理で落とし直さない）。
    public static func retryDelay(attempts: Int) -> TimeInterval {
        min(86_400, 600 * pow(2, Double(max(0, min(attempts, 16) - 1))))
    }
}

public extension Store {
    /// いまは取り込まない録音: 取り込み済み（会議を消したものも含む）と、取り込めずに次に試す時刻を待っているもの。
    func cloudRecordingsToSkip(now: Date = Date()) throws -> Set<String> {
        try writer.read { db in
            Set(try CloudImportRecord.fetchAll(db).filter { $0.importStatus == .imported || $0.retryAt > now }.map(\.recordingId))
        }
    }

    func cloudImport(recordingId: String) throws -> CloudImportRecord? {
        try writer.read { db in try CloudImportRecord.fetchOne(db, key: recordingId) }
    }

    /// サーバーの録音から会議を作る。会議の行・後処理の依頼・取り込みの記録を 1 つのトランザクションで書く。
    /// すでに取り込み済みの録音（ほかの取り込みが先に終えた）なら、何も書かずに nil を返す。
    func createCloudMeeting(_ meeting: MeetingRecord) throws -> MeetingRecord? {
        guard let recordingId = meeting.cloudRecordingId else { throw StoreError.notFound("サーバーの録音の ID") }
        guard meeting.audioDirectoryURL != nil else { throw PipelineError.noAudio(meeting.id) }
        var record = meeting
        record.meetingStatus = .finalizing
        record.cloudProcessed = true
        record.createdAt = Date()
        record.updatedAt = record.createdAt
        return try writer.write { db in
            if let existing = try CloudImportRecord.fetchOne(db, key: recordingId), existing.importStatus == .imported { return nil }
            try record.insert(db)
            try db.execute(sql: "INSERT INTO post_processing_jobs(meeting_id, status, enqueued_at) VALUES (?, 'queued', ?)",
                           arguments: [record.id, Store.isoString(Date())])
            try CloudImportRecord(recordingId: recordingId, meetingId: record.id, status: .imported, attempts: 0, attemptedAt: record.createdAt, error: nil).save(db)
            return record
        }
    }

    /// 取り込めなかった録音を覚える（次は間をあけて試す）。取り込み済みの記録は書き換えない。
    func recordCloudImportFailure(recordingId: String, error: String, now: Date = Date()) throws {
        try writer.write { db in
            let previous = try CloudImportRecord.fetchOne(db, key: recordingId)
            guard previous?.importStatus != .imported else { return }
            try CloudImportRecord(recordingId: recordingId, meetingId: nil, status: .failed, attempts: (previous?.attempts ?? 0) + 1,
                                  attemptedAt: now, error: String(error.prefix(500))).save(db)
        }
    }
}
