import CryptoKit
import Foundation

/// やることの済みの同期（P7、SPEC §5.6）。この Mac で付けた・外した済みをサーバーへ送り、iPhone・ほかの Mac で付けた済みを手元の会議に重ねる。
/// - 対象は、iPhone・Watch から取り込んだ会議（サーバーの録音の ID で指す）と、Minutes クラウドへ同期した会議（Mac の会議の ID で指す）。
///   同期した会議は、同期を入れているあいだだけ（切っているあいだは、サーバーの会議を上げ直さないのと同じく、済みも送らず重ねない）。
/// - 送る: `cloud_action_pushes` の古い順。送れたら消す。回線・ログイン切れ・混雑ではやめて、残りは次の同期で送る。
///   サーバーにない会議・やること（404 など）は捨てる（同期した会議なら、次に上げ直す会議に済みが入っている）。
/// - 重ねる: `GET /v1/action-checks` を番号の順に読み、読んだところを `cloud_state` に覚える（サーバーとログインごと）。
///   このログインで付けた済みはサーバーが返さない。まだ送っていない手元の済みがあるやることには重ねない（手元のほうが新しい）。
///   重ねた済みはサーバーへ送り返さない。
/// 送ってから読む（送る前に読むと、送っていない手元の済みより古いものを重ねかねない。そのやることは重ねないが、順にしておく）。
public enum CloudActionSync {
    public struct Report: Sendable, Equatable {
        /// 送った済み
        public var pushed = 0
        /// 送らないことにした済み（サーバーにない会議・やること、同期を切っている会議）
        public var dropped = 0
        /// 手元の会議に重ねた済み
        public var applied = 0
        /// 重ねた会議
        public var changedMeetings: [String] = []
        /// 途中でやめた理由（回線・ログイン切れなど。残りは次の同期で続ける）
        public var interruption: String?

        public init() {}
    }

    /// 一度の同期で読む回数の上限（1 回 500 件）。残りは次の同期で読む。
    static let maxPages = 20

    public static func sync(client: MinutesCloudClient, store: Store, includesMacMeetings: Bool) async -> Report {
        var report = Report()
        do {
            try await push(client: client, store: store, includesMacMeetings: includesMacMeetings, report: &report)
            try await pull(client: client, store: store, includesMacMeetings: includesMacMeetings, report: &report)
        } catch {
            report.interruption = error.localizedDescription
        }
        return report
    }

    static func push(client: MinutesCloudClient, store: Store, includesMacMeetings: Bool, report: inout Report) async throws {
        for push in try store.pendingCloudActionPushes() {
            try Task.checkCancellation()
            do {
                if let recordingID = push.cloudRecordingId {
                    try await client.setActionDone(recordingID: recordingID, actionID: push.actionId, done: push.done)
                } else if includesMacMeetings {
                    try await client.setMeetingActionDone(meetingID: push.meetingId, actionID: push.actionId, done: push.done)
                } else {
                    try store.finishCloudActionPush(push)
                    report.dropped += 1
                    continue
                }
                try store.finishCloudActionPush(push)
                report.pushed += 1
            } catch {
                if stopsSync(error) { throw error }
                // サーバーにない会議・やること、形の誤り: 送り直しても通らない
                try store.finishCloudActionPush(push)
                report.dropped += 1
            }
        }
    }

    static func pull(client: MinutesCloudClient, store: Store, includesMacMeetings: Bool, report: inout Report) async throws {
        guard let key = cursorKey(client: client) else { throw MinutesCloudError.notSignedIn }
        var after = Int(try store.cloudState(key) ?? "") ?? 0
        for _ in 0..<maxPages {
            try Task.checkCancellation()
            let page = try await client.actionChecks(after: after)
            // 後処理の途中の会議（議事録がまだない）を指す済みがあれば、読んだところをその直前で止め、次の同期で読み直す。
            // サーバーはやることごとに最新の済みだけを返すので、読み直しても古い済みで戻すことはない（同じ済みは何もしない）
            var heldAt: Int?
            var lastSeq = after
            for check in page.checks {
                defer { lastSeq = check.seq }
                guard let meetingId = try localMeeting(for: check, store: store, includesMacMeetings: includesMacMeetings) else { continue }
                switch try store.applyCloudActionCheck(meetingId: meetingId, actionId: check.actionId, done: check.done) {
                case .applied:
                    report.applied += 1
                    if !report.changedMeetings.contains(meetingId) { report.changedMeetings.append(meetingId) }
                case .unchanged:
                    break
                case .notReady:
                    if heldAt == nil { heldAt = lastSeq }
                }
            }
            let reached = heldAt ?? page.next
            if reached != after {
                after = reached
                try store.setCloudState(key, String(after))
            }
            guard heldAt == nil, page.more else { break }
        }
    }

    /// 済みを重ねる手元の会議。同期した Mac の会議は Mac の会議の ID（同期を入れているときだけ）、iPhone・Watch の録音は取り込んだ会議。
    static func localMeeting(for check: MinutesCloudActionCheck, store: Store, includesMacMeetings: Bool) throws -> String? {
        if check.kind == "meeting" {
            guard includesMacMeetings, let meetingId = check.meetingId, let meeting = try store.meeting(id: meetingId), meeting.cloudRecordingId == nil else { return nil }
            return meeting.id
        }
        return try store.meetingId(forCloudRecording: check.recordingId)
    }

    /// 読んだところを覚えるキー（サーバーとログインごと。ログインし直したら、はじめから読み直す。印そのものは書かない）。
    static func cursorKey(client: MinutesCloudClient) -> String? {
        guard let token = client.token(), !token.isEmpty else { return nil }
        let login = SHA256.hash(data: Data("minutes-action-checks:\(token)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "action_checks_after/\(client.baseURL.host() ?? "-")/\(login)"
    }

    /// 同期全体をやめる誤り（回線・ログイン切れ・有料でない・混雑・サーバーの誤り・中止）。残りは次の同期で続ける。
    static func stopsSync(_ error: Error) -> Bool {
        if error is CancellationError || error is URLError { return true }
        guard let cloud = error as? MinutesCloudError else { return false }
        if case .notSignedIn = cloud { return true }
        guard let status = cloud.status else { return false }
        return status == 401 || status == 402 || status == 429 || status >= 500
    }
}
