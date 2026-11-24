import Foundation
@testable import MinutesCore
import Synchronization
import Testing

/// やることの済みの同期（P7、`CloudActionSync`）。会議と本文は架空。サーバーはテスト用の URLProtocol。
@Suite("やることの済みの同期")
struct CloudActionSyncTests {
    typealias Answer = (status: Int, headers: [String: String], body: Data)

    /// テスト用のサーバー: 道ごとの答えと、届いた要求
    final class Server: Sendable {
        let requests = Mutex<[StubURLProtocol.Request]>([])
        let answer: @Sendable (StubURLProtocol.Request) -> Answer

        init(answer: @escaping @Sendable (StubURLProtocol.Request) -> Answer) {
            self.answer = answer
        }

        func client(token: String = "fictional-token") -> MinutesCloudClient {
            let base = StubURLProtocol.host { [self] request in
                requests.withLock { $0.append(request) }
                return answer(request)
            }
            return MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { token })
        }

        var puts: [StubURLProtocol.Request] { requests.withLock { $0.filter { $0.method == "PUT" } } }
        var feedQueries: [String] { requests.withLock { $0.filter { $0.path == "/v1/action-checks" }.map { $0.query ?? "" } } }
    }

    static func reply(_ object: Any, status: Int = 200) -> Answer {
        (status, ["content-type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }

    static let emptyFeed = reply(["checks": [], "next": 0, "more": false])

    /// 済みのない 2 つのやること（ID は a1・a2）を持つ会議
    func meeting(_ store: Store, cloudRecordingId: String? = nil, synced: Bool = false) throws -> MeetingRecord {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let meeting = try store.createMeeting(MeetingRecord(title: "架空の定例", startedAt: started, endedAt: started.addingTimeInterval(600), privacyMode: .cloudOk,
                                                            status: .done, cloudRecordingId: cloudRecordingId))
        let summary = MinutesSummary(summaryMd: "- 架空の要約", decisions: [],
                                     actionItems: [.init(text: "架空の資料を直す", owner: "spk_0", kind: .theirTask, due: nil, evidence: [], id: "a1"),
                                                   .init(text: "架空の日程を送る", owner: "me", kind: .ownCommitment, due: nil, evidence: [], id: "a2")],
                                     openQuestions: [], keytermsLearned: [])
        try store.upsertNotes(NotesRecord(meetingId: meeting.id, summary: summary, model: "test"))
        if synced { _ = try store.logExport(meetingId: meeting.id, target: MinutesCloudSyncTarget.targetID, status: .ok) }
        return meeting
    }

    func action(_ store: Store, _ meetingId: String, _ id: String) throws -> MinutesSummary.ActionItem {
        try #require(try store.notes(meetingId: meetingId)?.actionItems.first { $0.id == id })
    }

    @Test("済みを変えると、サーバーにある会議（取り込んだ会議・同期した会議）だけ送る列に入る。同じやることは最新の 1 つ")
    func queueOnlyServerMeetings() throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1")
        let synced = try meeting(store, synced: true)
        let local = try meeting(store)
        for target in [imported, synced, local] {
            _ = try store.setActionCompletion(meetingId: target.id, action: try action(store, target.id, "a1"), done: true)
        }
        _ = try store.setActionCompletion(meetingId: imported.id, action: try action(store, imported.id, "a1"), done: false)
        let pushes = try store.pendingCloudActionPushes()
        #expect(pushes.count == 2)
        #expect(pushes.contains(CloudActionPush(meetingId: imported.id, actionId: "a1", done: false, cloudRecordingId: "rec-1")))
        #expect(pushes.contains(CloudActionPush(meetingId: synced.id, actionId: "a1", done: true, cloudRecordingId: nil)))
    }

    @Test("送る: 取り込んだ会議は録音の ID で、同期した会議は Mac の会議の ID で送る。送れたら列から消す。ないやること（404）は捨てる")
    func push() async throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1")
        let synced = try meeting(store, synced: true)
        _ = try store.setActionCompletion(meetingId: imported.id, action: try action(store, imported.id, "a1"), done: true)
        _ = try store.setActionCompletion(meetingId: synced.id, action: try action(store, synced.id, "a2"), done: true)
        _ = try store.setActionCompletion(meetingId: synced.id, action: try action(store, synced.id, "a1"), done: true)
        let server = Server { request in
            if request.path == "/v1/action-checks" { return Self.emptyFeed }
            if request.path.hasSuffix("/actions/a1"), request.path.hasPrefix("/v1/meetings/") { return Self.reply(["error": "action_not_found"], status: 404) }
            return Self.reply(["action": ["id": "x", "done": true, "updated_at": "2026-11-24T00:00:00.000Z"]])
        }
        let report = await CloudActionSync.sync(client: server.client(), store: store, includesMacMeetings: true)
        #expect(report.pushed == 2 && report.dropped == 1 && report.interruption == nil)
        #expect(try store.pendingCloudActionPushCount() == 0)
        let paths = Set(server.puts.map(\.path))
        #expect(paths == ["/v1/recordings/rec-1/actions/a1", "/v1/meetings/\(synced.id)/actions/a2", "/v1/meetings/\(synced.id)/actions/a1"])
        let body = try #require(server.puts.first { $0.path == "/v1/recordings/rec-1/actions/a1" }?.body)
        #expect((try JSONSerialization.jsonObject(with: body) as? [String: Bool]) == ["done": true])
    }

    @Test("回線・サーバーの誤りでは送るのをやめ、列に残す（次の同期で送る）")
    func pushInterrupted() async throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1")
        _ = try store.setActionCompletion(meetingId: imported.id, action: try action(store, imported.id, "a1"), done: true)
        let server = Server { _ in Self.reply(["error": "internal"], status: 503) }
        let report = await CloudActionSync.sync(client: server.client(), store: store, includesMacMeetings: true)
        #expect(report.pushed == 0 && report.interruption != nil)
        #expect(try store.pendingCloudActionPushCount() == 1)
        #expect(server.feedQueries.isEmpty)
    }

    @Test("同期を切っているあいだは、同期した会議の済みを送らず（列から捨てる）、重ねない。取り込んだ会議はふだんどおり")
    func syncOff() async throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1")
        let synced = try meeting(store, synced: true)
        _ = try store.setActionCompletion(meetingId: synced.id, action: try action(store, synced.id, "a1"), done: true)
        let server = Server { request in
            guard request.path == "/v1/action-checks" else { return Self.reply(["action": [:]]) }
            return Self.reply(["checks": [
                ["recording_id": "srv-meeting", "kind": "meeting", "meeting_id": synced.id, "source": "mac", "action_id": "a2", "done": true, "updated_at": "2026-11-24T00:00:00.000Z", "seq": 3],
                ["recording_id": "rec-1", "kind": "recording", "meeting_id": NSNull(), "source": "iphone", "action_id": "a2", "done": true, "updated_at": "2026-11-24T00:00:00.000Z", "seq": 4],
            ], "next": 4, "more": false])
        }
        let report = await CloudActionSync.sync(client: server.client(), store: store, includesMacMeetings: false)
        #expect(report.pushed == 0 && report.dropped == 1 && report.applied == 1)
        #expect(server.puts.isEmpty)
        #expect(try action(store, synced.id, "a2").done != true)
        #expect(try action(store, imported.id, "a2").done == true)
    }

    @Test("重ねる: 番号の順に読んで手元の会議の済みにし、読んだところを覚える（次は after から）。送る列には入れない")
    func pull() async throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1")
        let synced = try meeting(store, synced: true)
        let server = Server { request in
            guard request.path == "/v1/action-checks" else { return Self.reply([:], status: 404) }
            if request.query?.contains("after=0") == true {
                return Self.reply(["checks": [
                    ["recording_id": "rec-1", "kind": "recording", "meeting_id": NSNull(), "source": "iphone", "action_id": "a1", "done": true, "updated_at": "2026-11-24T00:00:00.000Z", "seq": 5],
                    ["recording_id": "srv-meeting", "kind": "meeting", "meeting_id": synced.id, "source": "mac", "action_id": "a2", "done": true, "updated_at": "2026-11-24T00:00:01.000Z", "seq": 6],
                    // 手元にない会議・やることは飛ばす
                    ["recording_id": "rec-unknown", "kind": "recording", "meeting_id": NSNull(), "source": "watch", "action_id": "a1", "done": true, "updated_at": "2026-11-24T00:00:02.000Z", "seq": 7],
                    ["recording_id": "rec-1", "kind": "recording", "meeting_id": NSNull(), "source": "iphone", "action_id": "zz", "done": true, "updated_at": "2026-11-24T00:00:03.000Z", "seq": 8],
                ], "next": 9, "more": false])
            }
            return Self.reply(["checks": [], "next": 9, "more": false])
        }
        let client = server.client()
        let first = await CloudActionSync.sync(client: client, store: store, includesMacMeetings: true)
        #expect(first.applied == 2 && first.interruption == nil)
        #expect(Set(first.changedMeetings) == [imported.id, synced.id])
        #expect(try action(store, imported.id, "a1").done == true)
        #expect(try action(store, synced.id, "a2").done == true)
        #expect(try store.pendingCloudActionPushCount() == 0)
        let second = await CloudActionSync.sync(client: client, store: store, includesMacMeetings: true)
        #expect(second.applied == 0)
        #expect(server.feedQueries == ["after=0", "after=9"])
        // ログインし直したら（印が変わったら）はじめから読む
        _ = await CloudActionSync.sync(client: server.client(token: "another-token"), store: store, includesMacMeetings: true)
        #expect(server.feedQueries.last == "after=0")
    }

    @Test("まだ送っていない手元の済みがあるやることには、サーバーの済みを重ねない（手元のほうが新しい）")
    func pendingWins() throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1")
        _ = try store.setActionCompletion(meetingId: imported.id, action: try action(store, imported.id, "a1"), done: true)
        #expect(try store.applyCloudActionCheck(meetingId: imported.id, actionId: "a1", done: false) == .unchanged)
        #expect(try action(store, imported.id, "a1").done == true)
        #expect(try store.applyCloudActionCheck(meetingId: imported.id, actionId: "a2", done: true) == .applied)
    }

    @Test("取り込んだばかりで後処理の途中の会議（議事録がまだない）を指す済みは、読んだところをその直前で止め、議事録ができてから重ねる")
    func holdsUntilProcessed() async throws {
        let store = try Store.inMemory()
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        // 取り込んだ直後の会議: 行はあるが、後処理（議事録の保存）はまだ
        let pending = try store.createMeeting(MeetingRecord(title: "架空の取り込んだ会議", startedAt: started, privacyMode: .cloudOk, status: .finalizing, cloudRecordingId: "rec-new"))
        let other = try meeting(store, cloudRecordingId: "rec-1")
        let server = Server { request in
            guard request.path == "/v1/action-checks" else { return Self.reply([:], status: 404) }
            if request.query?.contains("after=0") == true || request.query?.contains("after=3") == true {
                return Self.reply(["checks": [
                    ["recording_id": "rec-1", "kind": "recording", "meeting_id": NSNull(), "source": "iphone", "action_id": "a1", "done": true, "updated_at": "2026-11-24T00:00:00.000Z", "seq": 3],
                    ["recording_id": "rec-new", "kind": "recording", "meeting_id": NSNull(), "source": "iphone", "action_id": "a1", "done": true, "updated_at": "2026-11-24T00:00:01.000Z", "seq": 5],
                    ["recording_id": "rec-1", "kind": "recording", "meeting_id": NSNull(), "source": "iphone", "action_id": "a2", "done": true, "updated_at": "2026-11-24T00:00:02.000Z", "seq": 7],
                ].filter { (($0["seq"] as? Int) ?? 0) > (request.query?.contains("after=3") == true ? 3 : 0) }, "next": 7, "more": false])
            }
            return Self.reply(["checks": [], "next": 7, "more": false])
        }
        let client = server.client()
        let first = await CloudActionSync.sync(client: client, store: store, includesMacMeetings: true)
        // ほかの会議の済みは重ねるが、読んだところは議事録のない会議の済みの直前（3）で止める
        #expect(first.applied == 2 && first.interruption == nil)
        #expect(try action(store, other.id, "a1").done == true && action(store, other.id, "a2").done == true)
        // 議事録ができた（後処理が終わった）
        let summary = MinutesSummary(summaryMd: "- 架空", decisions: [], actionItems: [.init(text: "架空の宿題", owner: "me", kind: .ownCommitment, due: nil, evidence: [], id: "a1")],
                                     openQuestions: [], keytermsLearned: [])
        try store.upsertNotes(NotesRecord(meetingId: pending.id, summary: summary, model: "cloud"))
        try store.setMeetingStatus(id: pending.id, status: .done)
        let second = await CloudActionSync.sync(client: client, store: store, includesMacMeetings: true)
        #expect(second.applied == 1 && second.changedMeetings == [pending.id])
        #expect(try action(store, pending.id, "a1").done == true)
        let third = await CloudActionSync.sync(client: client, store: store, includesMacMeetings: true)
        #expect(third.applied == 0)
        #expect(server.feedQueries == ["after=0", "after=3", "after=7"])
    }

    @Test("議事録のないまま終わった・失敗した会議を指す済みでは止めない（重ねる先がない）")
    func doesNotHoldForFinishedMeetingWithoutNotes() throws {
        let store = try Store.inMemory()
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let failed = try store.createMeeting(MeetingRecord(title: "架空の失敗した会議", startedAt: started, privacyMode: .cloudOk, status: .failed, cloudRecordingId: "rec-x"))
        #expect(try store.applyCloudActionCheck(meetingId: failed.id, actionId: "a1", done: true) == .unchanged)
        let processing = try store.createMeeting(MeetingRecord(title: "架空の後処理中の会議", startedAt: started, privacyMode: .cloudOk, status: .finalizing, cloudRecordingId: "rec-y"))
        #expect(try store.applyCloudActionCheck(meetingId: processing.id, actionId: "a1", done: true) == .notReady)
    }

    @Test("サーバーの要約のやることの ID は、取り込んだ会議でもそのまま使う（ID のないものだけ採番する）")
    func keepsServerActionIDs() throws {
        let store = try Store.inMemory()
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let meeting = try store.createMeeting(MeetingRecord(title: "架空の定例", startedAt: started, privacyMode: .cloudOk, status: .done, cloudRecordingId: "rec-1"))
        let summary = MinutesSummary(summaryMd: "- 架空", decisions: [],
                                     actionItems: [.init(text: "架空の宿題", owner: "me", kind: .ownCommitment, due: nil, evidence: [], done: true, id: "a_0123456789abcdef0123"),
                                                   .init(text: "架空の宿題 2", owner: "me", kind: .ownCommitment, due: nil, evidence: [])],
                                     openQuestions: [], keytermsLearned: [])
        let fingerprint = try PipelineFingerprint.encoded(try store.summaryInput(meetingId: meeting.id))
        try store.saveGeneratedSummary(meetingId: meeting.id, summary: summary, model: "cloud", inputFingerprint: fingerprint)
        let actions = try #require(try store.notes(meetingId: meeting.id)?.actionItems)
        #expect(actions[0].id == "a_0123456789abcdef0123" && actions[0].done == true)
        #expect(actions[1].id != nil && actions[1].id != actions[0].id)
    }
}
