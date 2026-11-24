import Foundation
import GRDB

/// 同期した Mac の会議（P7）の記録。どの同期先へ送ったかは export_log に残す（会議を消しても行は残る。消すのを待つ印に使う）。
public extension Store {
    /// 消した会議を、同期先からも消す同期先（会議の行がなくても消せるもの）。Minutes クラウド（サーバーの会議）だけ。
    static let remoteRemovalTargets: [String] = [MinutesCloudSyncTarget.targetID]

    /// 同期先から消すのを待っているもの（target ごとの最新の記録が remove_pending）。
    func pendingRemovals() throws -> [ExportLogRecord] {
        try writer.read { db in
            try ExportLogRecord.fetchAll(db, sql: """
            SELECT e.* FROM export_log e
            WHERE e.id = (SELECT MAX(id) FROM export_log WHERE meeting_id = e.meeting_id AND target = e.target)
              AND e.status = 'remove_pending'
            ORDER BY e.id
            """)
        }
    }

    /// 同期を入れたときに送る会議: 終わった・クラウド OK・iPhone・Watch から取り込んだ会議でない（取り込んだ会議はサーバーにもとの録音がある）。新しい順。
    func meetingIdsForCloudSync() throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: """
            SELECT id FROM meetings
            WHERE status = 'done' AND privacy_mode = 'cloud_ok' AND cloud_recording_id IS NULL
            ORDER BY started_at DESC
            """)
        }
    }

    /// 会議をまとめて送る（pending にする。送るのは `PostProcessPipeline.retryPendingExports`）。
    func queueExports(meetingIds: [String], target: String) throws {
        try writer.write { db in
            for id in meetingIds {
                var record = ExportLogRecord(meetingId: id, target: target, status: .pending)
                try record.insert(db)
            }
        }
    }

    /// 会議の行を消す同じトランザクションで: 消す前の記録で同期先へ送っていた（最新が ok か pending）なら、消すのを待つ印を残す。
    internal static func recordRemoteRemovals(_ db: Database, meetingId: String, previous: [String: String]) throws {
        for target in remoteRemovalTargets {
            guard let status = previous[target], status == ExportStatus.ok.rawValue || status == ExportStatus.pending.rawValue else { continue }
            var record = ExportLogRecord(meetingId: meetingId, target: target, status: .removePending)
            try record.insert(db)
        }
    }

    /// この同期先へ送ったことがある会議か（最新の記録が ok・pending・remove_pending）。
    func wasSynced(meetingId: String, target: String) throws -> Bool {
        let status = try writer.read { db in try Store.latestExportStatuses(db, meetingId: meetingId)[target] }
        return [ExportStatus.ok, .pending, .removePending].map(\.rawValue).contains(status ?? "")
    }

    /// 同期先ごとの最新の記録（target → status）。
    internal static func latestExportStatuses(_ db: Database, meetingId: String) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT target, status FROM export_log e
        WHERE meeting_id = ? AND id = (SELECT MAX(id) FROM export_log WHERE meeting_id = e.meeting_id AND target = e.target)
        """, arguments: [meetingId])
        return Dictionary(rows.map { ($0["target"] as String, $0["status"] as String) }, uniquingKeysWith: { a, _ in a })
    }
}
