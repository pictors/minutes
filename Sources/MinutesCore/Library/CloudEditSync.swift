import CryptoKit
import Foundation

/// 題名・話者の名前の同期（P7、SPEC §5.6）。iPhone・ほかの Mac で直した題名と話者の名前を手元の会議に当て、iPhone・Watch から
/// 取り込んだ会議をこの Mac で直したものをサーバーへ送る。
/// - 送る: `cloud_edit_pushes` を会議ごとにまとめて `PATCH /v1/recordings/:id`（取り込んだ会議だけ。同期した Mac の会議は、上げ直しが
///   題名と名前を運ぶ）。送れたら消す。回線・ログイン切れ・混雑ではやめて、残りは次の同期で送る。サーバーにない会議・話者（404・400）は捨てる。
/// - 当てる: `GET /v1/meeting-edits` を番号の順に読み、読んだところを `cloud_state` に覚える（サーバーとログインごと）。このログインで
///   直したものはサーバーが返さない。まだ送っていない手元の直しがある欄には当てない。当てた直しはサーバーへ送り返さない。
///   同期した Mac の会議の直しは、同期を切っているあいだも当てる（読んだところだけ進めて飛ばすと、同期を入れ直したときの上げ直しで、
///   サーバーがその直しを Mac が読んだものとして消してしまう）。
///   後処理の途中の取り込んだ会議（話者がまだない）を指す直しがあれば、読んだところをその直前で止め、次の同期で読み直す。
/// - 読んだところは、同期した会議の上げ直しに edits_seen として付ける（`editsSeen`、`MinutesCloudSyncTarget`）。サーバーは、これより
///   新しい直し（この Mac がまだ当てていない）を上げ直しの上からかぶせ直し、読んだ直しの行を消す。
/// 送ってから読む（済みと同じ順。送る前に読むと、送っていない手元の直しより古いものを当てかねない。その欄は当てないが、順にしておく）。
public enum CloudEditSync {
    public struct Report: Sendable, Equatable {
        /// 送った直し
        public var pushed = 0
        /// 送らないことにした直し（サーバーにない会議・話者）
        public var dropped = 0
        /// 手元の会議に当てた直し
        public var applied = 0
        /// 当てた会議（書き出しと同期をやり直す）
        public var changedMeetings: [String] = []
        /// 途中でやめた理由（回線・ログイン切れなど。残りは次の同期で続ける）
        public var interruption: String?

        public init() {}
    }

    /// 一度の同期で読む回数の上限（1 回 500 件）。残りは次の同期で読む。
    static let maxPages = 20

    public static func sync(client: MinutesCloudClient, store: Store) async -> Report {
        var report = Report()
        do {
            try await push(client: client, store: store, report: &report)
            try await pull(client: client, store: store, report: &report)
        } catch {
            report.interruption = error.localizedDescription
        }
        return report
    }

    static func push(client: MinutesCloudClient, store: Store, report: inout Report) async throws {
        let pushes = try store.pendingCloudEditPushes()
        // 会議ごとにまとめて 1 回で送る（古い順）
        var order: [String] = []
        var byMeeting: [String: [CloudEditPush]] = [:]
        for push in pushes {
            if byMeeting[push.meetingId] == nil { order.append(push.meetingId) }
            byMeeting[push.meetingId, default: []].append(push)
        }
        for meetingId in order {
            try Task.checkCancellation()
            guard let group = byMeeting[meetingId], let recordingId = group.first?.cloudRecordingId else { continue }
            let title = group.first(where: { $0.field == CloudEditField.title })?.value
            var names: [String: String] = [:]
            for push in group {
                // 名前を消したものは空で送る（サーバーは空を「消す」と読む）
                if let label = CloudEditField.label(of: push.field) { names[label] = push.value ?? "" }
            }
            do {
                if title != nil || !names.isEmpty {
                    _ = try await client.updateRecording(id: recordingId, title: title, speakerNames: names.isEmpty ? nil : names)
                }
                for push in group { try store.finishCloudEditPush(push) }
                report.pushed += group.count
            } catch {
                if CloudActionSync.stopsSync(error) { throw error }
                // サーバーにない会議・話者、形の誤り: 送り直しても通らない
                for push in group { try store.finishCloudEditPush(push) }
                report.dropped += group.count
            }
        }
    }

    static func pull(client: MinutesCloudClient, store: Store, report: inout Report) async throws {
        guard let key = cursorKey(client: client) else { throw MinutesCloudError.notSignedIn }
        var after = Int(try store.cloudState(key) ?? "") ?? 0
        for _ in 0..<maxPages {
            try Task.checkCancellation()
            let page = try await client.meetingEdits(after: after)
            var heldAt: Int?
            var lastSeq = after
            for edit in page.edits {
                defer { lastSeq = edit.seq }
                guard let meetingId = try localMeeting(for: edit, store: store), let field = field(of: edit) else { continue }
                switch try store.applyCloudMeetingEdit(meetingId: meetingId, field: field, value: edit.value) {
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

    /// 直しを当てる手元の会議。同期した Mac の会議は Mac の会議の ID（同期を切っていても当てる）、iPhone・Watch の録音は取り込んだ会議。
    static func localMeeting(for edit: MinutesCloudMeetingEdit, store: Store) throws -> String? {
        if edit.kind == "meeting" {
            guard let meetingId = edit.meetingId, let meeting = try store.meeting(id: meetingId), meeting.cloudRecordingId == nil else { return nil }
            return meeting.id
        }
        return try store.meetingId(forCloudRecording: edit.recordingId)
    }

    /// 手元の記録の欄（"title" か "speaker:<ラベル>"）。知らない欄は nil。
    static func field(of edit: MinutesCloudMeetingEdit) -> String? {
        switch edit.field {
        case "title": CloudEditField.title
        case "speaker": edit.label.flatMap { $0.isEmpty ? nil : CloudEditField.speaker($0) }
        default: nil
        }
    }

    /// 読んだところを覚えるキー（サーバーとログインごと。ログインし直したら、はじめから読み直す。印そのものは書かない）。
    static func cursorKey(client: MinutesCloudClient) -> String? {
        guard let token = client.token(), !token.isEmpty else { return nil }
        let login = SHA256.hash(data: Data("minutes-meeting-edits:\(token)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "meeting_edits_after/\(client.baseURL.host() ?? "-")/\(login)"
    }

    /// 同期した会議の上げ直しに付ける edits_seen（直しの記録を読んだところ。ログインしていなければ nil）。
    public static func editsSeen(client: MinutesCloudClient, store: Store) -> Int? {
        guard let key = cursorKey(client: client) else { return nil }
        return Int((try? store.cloudState(key)) ?? "") ?? 0
    }
}
