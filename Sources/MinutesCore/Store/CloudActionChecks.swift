import Foundation
import GRDB

/// やることの済みの同期（P7、SPEC §5.6）の手元の記録。送る・重ねるのは `CloudActionSync`。
/// - `cloud_action_pushes`: この Mac で付けた・外した済みのうち、まだサーバーへ送っていないもの（会議・やることごとに最新の 1 つ）。
///   送れたら消す。回線がなければ残して、次の同期で送る。会議を消すと外部キーで消える。
/// - `cloud_state`: サーバーの済みをどこまで読んだかなど（キーと値）。
public struct CloudActionPush: Sendable, Equatable {
    public var meetingId: String
    public var actionId: String
    public var done: Bool
    /// iPhone・Watch から取り込んだ会議なら、サーバーの録音の ID（なければ同期した Mac の会議。Mac の会議の ID で送る）
    public var cloudRecordingId: String?

    public init(meetingId: String, actionId: String, done: Bool, cloudRecordingId: String?) {
        self.meetingId = meetingId
        self.actionId = actionId
        self.done = done
        self.cloudRecordingId = cloudRecordingId
    }
}

public extension Store {
    /// まだ送っていない済み（古い順）。
    func pendingCloudActionPushes() throws -> [CloudActionPush] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
            SELECT p.meeting_id, p.action_id, p.done, m.cloud_recording_id FROM cloud_action_pushes p
            JOIN meetings m ON m.id = p.meeting_id
            ORDER BY p.queued_at, p.rowid
            """).map { row in
                CloudActionPush(meetingId: row["meeting_id"], actionId: row["action_id"], done: row["done"], cloudRecordingId: row["cloud_recording_id"])
            }
        }
    }

    func pendingCloudActionPushCount() throws -> Int {
        try writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_action_pushes") ?? 0 }
    }

    func pendingCloudActionPushObservation() -> ValueObservation<ValueReducers.Fetch<Int>> {
        ValueObservation.tracking { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_action_pushes") ?? 0 }
    }

    /// 送れた（または送らないことにした）済みを消す。送っているあいだに付け直していれば（done が違えば）残す。
    func finishCloudActionPush(_ push: CloudActionPush) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM cloud_action_pushes WHERE meeting_id = ? AND action_id = ? AND done = ?",
                           arguments: [push.meetingId, push.actionId, push.done])
        }
    }

    func cloudState(_ key: String) throws -> String? {
        try writer.read { db in try String.fetchOne(db, sql: "SELECT value FROM cloud_state WHERE key = ?", arguments: [key]) }
    }

    func setCloudState(_ key: String, _ value: String) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO cloud_state(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        }
    }

    /// サーバーの録音（iPhone・Watch から取り込んだ会議）の会議の ID。
    func meetingId(forCloudRecording recordingId: String) throws -> String? {
        try writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM meetings WHERE cloud_recording_id = ?", arguments: [recordingId]) }
    }

    /// ほかの端末の済みを重ねた結果。
    enum CloudActionCheckApply: Equatable {
        /// 手元の済みを変えた
        case applied
        /// 何もしなかった（同じ済み・やることがない・まだ送っていないこの Mac の済みがある・議事録のないまま終わった会議）
        case unchanged
        /// 会議はあるが、まだ後処理の途中で議事録がない（取り込んだばかりの会議）。あとで読み直す
        case notReady
    }

    /// ほかの端末で付けた・外した済みを、手元の会議のやることに重ねる。サーバーへ送り返さない。
    /// やることがない・同じ済み・まだ送っていないこの Mac の済みがある（手元のほうが新しい）なら、何もしない。
    @discardableResult
    func applyCloudActionCheck(meetingId: String, actionId: String, done: Bool) throws -> CloudActionCheckApply {
        try writer.write { db in
            let pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloud_action_pushes WHERE meeting_id = ? AND action_id = ?)",
                                            arguments: [meetingId, actionId]) ?? false
            guard !pending else { return .unchanged }
            guard var notes = try NotesRecord.fetchOne(db, key: meetingId) else {
                // 取り込んだばかりで後処理を待っている会議は、議事録ができてから重ねる（ここで飛ばすと、取り込みのときの要約より
                // あとに付けた済みが届かない）。終わった・失敗した会議に議事録がなければ、重ねる先がない
                let status = try MeetingRecord.fetchOne(db, key: meetingId)?.meetingStatus
                return status == .done || status == .failed ? .unchanged : .notReady
            }
            var items = notes.actionItems
            guard let index = items.firstIndex(where: { $0.id == actionId }), (items[index].done ?? false) != done else { return .unchanged }
            items[index].done = done
            notes.setActionItems(items)
            try notes.save(db)
            return .applied
        }
    }

    /// サーバーにある会議か（iPhone・Watch から取り込んだ会議と、Minutes クラウドへ同期した会議）。同期した会議は、最後の記録が
    /// 送った・送る・送れなかった（上げ直しで失敗しただけなら、サーバーには前の版がある）のどれか。
    internal static func isOnMinutesCloud(_ db: Database, meetingId: String) throws -> Bool {
        guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { return false }
        if meeting.cloudRecordingId != nil { return true }
        let status = try latestExportStatuses(db, meetingId: meetingId)[MinutesCloudSyncTarget.targetID]
        return [ExportStatus.ok, .pending, .failed].map(\.rawValue).contains(status ?? "")
    }

    /// この Mac で付けた・外した済みを、サーバーへ送る列に入れる（サーバーにある会議だけ。同じやることは最新の 1 つにする）。
    internal static func queueCloudActionPush(_ db: Database, meetingId: String, actionId: String, done: Bool) throws {
        guard try isOnMinutesCloud(db, meetingId: meetingId) else { return }
        try db.execute(sql: """
        INSERT INTO cloud_action_pushes(meeting_id, action_id, done, queued_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(meeting_id, action_id) DO UPDATE SET done = excluded.done, queued_at = excluded.queued_at
        """, arguments: [meetingId, actionId, done, Store.isoString(Date())])
    }
}
