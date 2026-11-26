import Foundation
import GRDB

/// 題名・話者の名前の同期（P7、SPEC §5.6）の手元の記録。送る・当てるのは `CloudEditSync`。
/// - `cloud_edit_pushes`: iPhone・Watch から取り込んだ会議を、この Mac の画面で直したもののうち、まだサーバーへ送っていないもの
///   （会議・欄ごとに最新の 1 つ）。人が直したときだけ入れる（後処理が付けた名前や、取り込みの仮の題名は送らない）。送れたら消す。
/// - 同期した Mac の会議は、上げ直し（`MinutesCloudSyncTarget`）が題名と名前を運ぶので、ここには入れない。
/// - field は "title" か "speaker:<ラベル>"（サーバーの表 meeting_edits と同じ）。value の nil は名前を消した。
/// - 話者の名前は、取り込んだ会議がサーバーの文字起こしのままのとき（`cloud_processed`）だけ送る・当てる。言語を変えてこの Mac で
///   文字起こしし直した会議は、話者のラベル（spk_0 など）がサーバーの話者と別の人を指すので、題名だけを合わせる。
public struct CloudEditPush: Sendable, Equatable {
    public var meetingId: String
    public var field: String
    public var value: String?
    /// 取り込んだ会議のサーバーの録音の ID
    public var cloudRecordingId: String

    public init(meetingId: String, field: String, value: String?, cloudRecordingId: String) {
        self.meetingId = meetingId
        self.field = field
        self.value = value
        self.cloudRecordingId = cloudRecordingId
    }
}

public enum CloudEditField {
    public static let title = "title"
    public static func speaker(_ label: String) -> String { "speaker:" + label }
    /// "speaker:<ラベル>" のラベル（題名なら nil）
    public static func label(of field: String) -> String? {
        field.hasPrefix("speaker:") ? String(field.dropFirst("speaker:".count)) : nil
    }
}

public extension Store {
    /// まだ送っていない直し（古い順。取り込んだ会議のものだけ）。
    func pendingCloudEditPushes() throws -> [CloudEditPush] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
            SELECT p.meeting_id, p.field, p.value, m.cloud_recording_id FROM cloud_edit_pushes p
            JOIN meetings m ON m.id = p.meeting_id
            WHERE m.cloud_recording_id IS NOT NULL
            ORDER BY p.queued_at, p.rowid
            """).map { row in
                CloudEditPush(meetingId: row["meeting_id"], field: row["field"], value: row["value"], cloudRecordingId: row["cloud_recording_id"])
            }
        }
    }

    func pendingCloudEditPushObservation() -> ValueObservation<ValueReducers.Fetch<Int>> {
        ValueObservation.tracking { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cloud_edit_pushes") ?? 0 }
    }

    /// 送れた（または送らないことにした）直しを消す。送っているあいだに直し直していれば（値が違えば）残す。
    func finishCloudEditPush(_ push: CloudEditPush) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM cloud_edit_pushes WHERE meeting_id = ? AND field = ? AND value IS ?",
                           arguments: [push.meetingId, push.field, push.value])
        }
    }

    /// ほかの端末の直しを当てた結果。
    enum CloudEditApply: Equatable {
        /// 手元の会議を変えた
        case applied
        /// 何もしなかった（同じ値・その話者がいない・まだ送っていないこの Mac の直しがある・空の題名）
        case unchanged
        /// 会議はあるが、まだ後処理の途中で話者がいない（取り込んだばかりの会議）。あとで読み直す
        case notReady
    }

    /// ほかの端末で直した題名・話者の名前を、手元の会議に当てる。サーバーへ送り返さない。
    /// - 題名: 空なら、取り込んだ会議は仮の題名（iPhone の録音・Apple Watch の録音）にし、Mac の会議は変えない。
    /// - 話者の名前: その話者（クラスタのラベル）の表示名にする。人物（声のサンプル）に結び付いていて、名前が人物と違えば結び付きを外す
    ///   （iPhone で直したのは、ほかの人だったという直し）。
    /// まだ送っていないこの Mac の直しがある欄は、手元のほうが新しいので当てない。
    @discardableResult
    func applyCloudMeetingEdit(meetingId: String, field: String, value: String?) throws -> CloudEditApply {
        try writer.write { db in
            let pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloud_edit_pushes WHERE meeting_id = ? AND field = ?)",
                                            arguments: [meetingId, field]) ?? false
            guard !pending, var meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { return .unchanged }
            let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = cleaned?.isEmpty == false ? cleaned : nil

            if field == CloudEditField.title {
                let title: String
                if let name {
                    title = name
                } else if meeting.cloudRecordingId != nil {
                    title = CloudMeetingImport.fallbackTitle(platform: meeting.meetingPlatform)
                } else {
                    return .unchanged
                }
                guard meeting.title != title || meeting.titleAuto else { return .unchanged }
                // ほかの端末で人が付けた題名（要約が題名を付ける印を外す）
                meeting.title = title
                meeting.titleAuto = false
                meeting.updatedAt = Date()
                try meeting.update(db)
                return .applied
            }

            guard let label = CloudEditField.label(of: field) else { return .unchanged }
            // この Mac で文字起こしし直した取り込んだ会議は、ラベルがサーバーの話者と合わない
            if meeting.cloudRecordingId != nil, !meeting.cloudProcessed { return .unchanged }
            guard var speaker = try SpeakerRecord.filter(Column("meeting_id") == meetingId && Column("cluster_label") == label).fetchOne(db) else {
                // 取り込んだばかりで後処理を待っている会議は、話者ができてから当てる
                let status = meeting.meetingStatus
                return status == .recording || status == .finalizing ? .notReady : .unchanged
            }
            let person = try speaker.personId.flatMap { try PersonRecord.fetchOne(db, key: $0) }
            let unlink = person != nil && person?.name != name
            guard speaker.displayName != name || unlink else { return .unchanged }
            speaker.displayName = name
            if unlink { speaker.personId = nil }
            try speaker.update(db)
            return .applied
        }
    }

    /// この Mac の画面で直した題名・話者の名前を、サーバーへ送る列に入れる（iPhone・Watch から取り込んだ会議だけ。同じ欄は最新の 1 つにする）。
    /// 話者の名前は、サーバーの文字起こしのままの会議（`cloud_processed`）だけ（この Mac で文字起こしし直すと、ラベルが合わない）。
    internal static func queueCloudEditPush(_ db: Database, meetingId: String, field: String, value: String?) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT cloud_recording_id, cloud_processed FROM meetings WHERE id = ?", arguments: [meetingId]),
              (row["cloud_recording_id"] as String?) != nil else { return }
        if CloudEditField.label(of: field) != nil, !(row["cloud_processed"] as Bool? ?? false) { return }
        try db.execute(sql: """
        INSERT INTO cloud_edit_pushes(meeting_id, field, value, queued_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(meeting_id, field) DO UPDATE SET value = excluded.value, queued_at = excluded.queued_at
        """, arguments: [meetingId, field, value, Store.isoString(Date())])
    }
}
