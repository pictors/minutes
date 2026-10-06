import Foundation
import GRDB

public enum PostProcessingStatus: String, Codable, Sendable {
    case queued, running, failed
}

/// 録音の寿命とは独立した後処理依頼。成功後は削除し、履歴は pipeline_runs に残す。
public struct PostProcessingJob: MinutesRecord, Identifiable, Equatable {
    public static let databaseTableName = "post_processing_jobs"
    public var id: String { meetingId }
    public var meetingId: String
    public var status: String
    public var enqueuedAt: Date
    public var startedAt: Date?
    public var error: String?
    public var jobStatus: PostProcessingStatus { PostProcessingStatus(rawValue: status) ?? .failed }
}

extension Store {
    public func postProcessingJobs() throws -> [PostProcessingJob] {
        try writer.read { db in try Self.fetchPostProcessingJobs(db) }
    }

    static func fetchPostProcessingJobs(_ db: Database) throws -> [PostProcessingJob] {
        try PostProcessingJob.fetchAll(db, sql: "SELECT * FROM post_processing_jobs ORDER BY enqueued_at, rowid")
    }

    public func postProcessingJobsObservation() -> ValueObservation<ValueReducers.Fetch<[PostProcessingJob]>> {
        ValueObservation.tracking { db in try Self.fetchPostProcessingJobs(db) }
    }

    /// 手動再試行。別の会議を録音中でも依頼でき、処理中・待機中の同じ依頼は増やさない。
    public func requestPostProcessing(meetingId: String) throws {
        if try postProcessingJobs().contains(where: { $0.meetingId == meetingId && $0.jobStatus != .failed }) { return }
        let lease = try acquireMeetingLease(meetingId)
        try enqueuePostProcessing(meetingId: meetingId, lease: lease)
    }

    /// 録音側は終了済みファイルとロックを保持したまま、終了状態とジョブを同時に保存する。
    func enqueuePostProcessing(meetingId: String, lease: MeetingLease, endedAt: Date? = nil) throws {
        try validateMeetingLease(lease, meetingId: meetingId)
        defer { withExtendedLifetime(lease) {} }
        try writer.write { db in
            guard var meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { throw StoreError.notFound(meetingId) }
            if let job = try PostProcessingJob.fetchOne(db, key: meetingId), job.jobStatus != .failed { return }
            guard endedAt != nil || meeting.meetingStatus == .failed else { throw StoreError.meetingBusy(meetingId) }
            guard meeting.audioDirectoryURL != nil else { throw PipelineError.noAudio(meetingId) }
            meeting.meetingStatus = .finalizing
            meeting.endedAt = endedAt ?? meeting.endedAt
            meeting.updatedAt = Date()
            try meeting.update(db)
            try db.execute(sql: """
                INSERT INTO post_processing_jobs(meeting_id, status, enqueued_at) VALUES (?, 'queued', ?)
                ON CONFLICT(meeting_id) DO UPDATE SET status = 'queued', enqueued_at = excluded.enqueued_at, started_at = NULL, error = NULL
                """, arguments: [meetingId, Store.isoString(Date())])
        }
    }

    /// ワーカーが会議ロックを取得してから実行する。CLI 等で完了済みなら依頼だけ消す。
    func beginPostProcessing(meetingId: String, lease: MeetingLease) throws -> Bool {
        try validateMeetingLease(lease, meetingId: meetingId)
        return try writer.write { db in
            guard let job = try PostProcessingJob.fetchOne(db, key: meetingId), job.jobStatus != .failed,
                  var meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { return false }
            if meeting.meetingStatus == .done {
                try db.execute(sql: "DELETE FROM post_processing_jobs WHERE meeting_id = ?", arguments: [meetingId])
                return false
            }
            guard meeting.meetingStatus != .recording else { throw StoreError.meetingBusy(meetingId) }
            meeting.meetingStatus = .finalizing
            meeting.updatedAt = Date()
            try meeting.update(db)
            try db.execute(sql: "UPDATE post_processing_jobs SET status = 'running', started_at = ?, error = NULL WHERE meeting_id = ?", arguments: [Store.isoString(Date()), meetingId])
            return true
        }
    }

    func finishPostProcessing(meetingId: String, lease: MeetingLease, error: String? = nil) throws {
        try validateMeetingLease(lease, meetingId: meetingId)
        try writer.write { db in
            if let error {
                try db.execute(sql: "UPDATE post_processing_jobs SET status = 'failed', error = ? WHERE meeting_id = ?", arguments: [error, meetingId])
                try db.execute(sql: "UPDATE meetings SET status = 'failed', updated_at = ? WHERE id = ?", arguments: [Store.isoString(Date()), meetingId])
            } else {
                try db.execute(sql: "DELETE FROM post_processing_jobs WHERE meeting_id = ?", arguments: [meetingId])
            }
        }
    }
}
