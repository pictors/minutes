import Foundation

/// 会議の Minutes クラウドへの最新の記録（`Store.cloudSyncRecords`）。
public struct CloudSyncRecord: Equatable, Sendable {
    public var status: ExportStatus
    /// 記録した時刻（送れたなら、送れた時刻）
    public var at: Date

    public init(status: ExportStatus, at: Date) {
        self.status = status
        self.at = at
    }
}

/// Mac の会議の一覧に出す同期の印（P7、SPEC §5.6。2026-11-25）。題名の右の、ローカルのみの鍵と同じ場所に出す。
/// 同期を入れていて、ログインしているときだけ出す（切っているときに全部の行へ「同期していない」と出しても、うるさいだけ）。
public enum CloudSyncMark: Equatable, Sendable {
    /// iPhone でも読める。送れた時刻（iPhone・Watch で録って取り込んだ会議は nil。もとの録音がサーバーにある）
    case synced(Date?)
    /// いま送っている（送り待ちとは分ける。回線が切れているあいだ回り続けないように）
    case syncing
    /// 送るのを待っている（回線・ログイン切れ・混雑。つながれば送る）
    case waiting
    /// 送れなかった（サーバーが形の誤りなどで断った。直して送り直す）
    case failed

    /// 印を決める。同期を入れていない・ログインしていない、ローカルのみの会議（鍵を出す）、まだ終わっていない会議、
    /// 送ったことのない会議、サーバーから消した・消すのを待つ会議は nil（印を出さない）。
    public static func make(meeting: MeetingRecord, record: CloudSyncRecord?, isSyncing: Bool, enabled: Bool) -> CloudSyncMark? {
        guard enabled, meeting.privacy == .cloudOk else { return nil }
        if isSyncing { return .syncing }
        if meeting.cloudRecordingId != nil { return .synced(nil) }
        guard meeting.meetingStatus == .done, let record else { return nil }
        switch record.status {
        case .ok: return .synced(record.at)
        case .pending: return .waiting
        case .failed: return .failed
        case .removePending, .removed: return nil
        }
    }
}
