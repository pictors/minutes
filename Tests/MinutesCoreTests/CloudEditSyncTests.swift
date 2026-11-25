import Foundation
@testable import MinutesCore
import Synchronization
import Testing

/// 題名・話者の名前の同期（P7、`CloudEditSync`）。会議・人名は架空。サーバーはテスト用の URLProtocol。
@Suite("題名・話者の名前の同期")
struct CloudEditSyncTests {
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

        var patches: [StubURLProtocol.Request] { requests.withLock { $0.filter { $0.method == "PATCH" } } }
        var feedQueries: [String] { requests.withLock { $0.filter { $0.path == "/v1/meeting-edits" }.map { $0.query ?? "" } } }
    }

    static func reply(_ object: Any, status: Int = 200) -> Answer {
        (status, ["content-type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }

    static let emptyFeed = reply(["edits": [], "next": 0, "more": false])
    static let recordingReply = reply(["recording": ["id": "rec-1", "client_id": "iphone-fictional-0001", "source": "iphone", "status": "done", "created_at": "2026-11-24T00:00:00.000Z"]])

    /// 話者 spk_0・spk_1 のいる会議（取り込んだ会議なら cloudRecordingId。取り込んだ会議は、ふつうはサーバーの文字起こしのまま（cloudProcessed）。
    /// Mac の会議なら nil）
    func meeting(_ store: Store, title: String = "架空の定例", cloudRecordingId: String? = nil, platform: MeetingPlatform? = nil,
                 status: MeetingStatus = .done, speakers: Bool = true, cloudProcessed: Bool? = nil) throws -> MeetingRecord {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let meeting = try store.createMeeting(MeetingRecord(title: title, startedAt: started, endedAt: started.addingTimeInterval(600), platform: platform,
                                                            privacyMode: .cloudOk, status: status, cloudRecordingId: cloudRecordingId,
                                                            cloudProcessed: cloudProcessed ?? (cloudRecordingId != nil)))
        if speakers {
            try store.replaceSpeakers(meetingId: meeting.id, with: [
                SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_0", personId: nil, displayName: "架空の山田"),
                SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_1", personId: nil, displayName: nil),
            ])
        }
        return meeting
    }

    func speaker(_ store: Store, _ meetingId: String, _ label: String) throws -> SpeakerRecord {
        try #require(try store.speakers(meetingId: meetingId).first { $0.clusterLabel == label })
    }

    static func edit(_ recordingId: String, kind: String = "recording", meetingId: String? = nil, field: String, label: String? = nil, value: String?, seq: Int) -> [String: Any] {
        ["recording_id": recordingId, "kind": kind, "meeting_id": meetingId as Any? ?? NSNull(), "source": kind == "meeting" ? "mac" : "iphone",
         "field": field, "label": label as Any? ?? NSNull(), "value": value as Any? ?? NSNull(), "updated_at": "2026-11-25T00:00:00.000Z", "seq": seq]
    }

    @Test("画面で直すと、取り込んだ会議だけ送る列に入る（同じ欄は最新の 1 つ。自分のマイク・Mac で足した話者は入れない）")
    func queueOnlyImportedMeetings() throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1", platform: .iphone)
        let mac = try meeting(store)
        for target in [imported, mac] { try store.updateMeetingTitle(id: target.id, title: "架空の定例（直した）") }
        try store.updateMeetingTitle(id: imported.id, title: "架空の定例（直し直した）")
        try store.assignSpeaker(meetingId: imported.id, clusterLabel: "spk_0", personId: nil, displayName: "架空の佐藤")
        try store.assignSpeaker(meetingId: imported.id, clusterLabel: "me", personId: nil, displayName: "架空の自分")
        try store.assignSpeaker(meetingId: imported.id, clusterLabel: "manual_1a2b3c4d", personId: nil, displayName: "架空の誰か")
        try store.assignSpeaker(meetingId: mac.id, clusterLabel: "spk_0", personId: nil, displayName: "架空の佐藤")
        let pushes = try store.pendingCloudEditPushes()
        #expect(pushes.count == 2)
        #expect(pushes.contains(CloudEditPush(meetingId: imported.id, field: CloudEditField.title, value: "架空の定例（直し直した）", cloudRecordingId: "rec-1")))
        #expect(pushes.contains(CloudEditPush(meetingId: imported.id, field: CloudEditField.speaker("spk_0"), value: "架空の佐藤", cloudRecordingId: "rec-1")))
        // 同じ題名に直しても列に入れない
        try store.finishCloudEditPush(pushes.first { $0.field == CloudEditField.title }!)
        try store.updateMeetingTitle(id: imported.id, title: "架空の定例（直し直した）")
        #expect(try store.pendingCloudEditPushes().count == 1)
    }

    @Test("送る: 会議ごとにまとめて PATCH /v1/recordings/:id。送れたら列から消す。ない会議（404）は捨てる")
    func push() async throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1", platform: .iphone)
        let gone = try meeting(store, cloudRecordingId: "rec-gone", platform: .watch)
        try store.updateMeetingTitle(id: imported.id, title: "架空の定例（Mac で直した）")
        try store.assignSpeaker(meetingId: imported.id, clusterLabel: "spk_0", personId: nil, displayName: "架空の佐藤")
        try store.assignSpeaker(meetingId: imported.id, clusterLabel: "spk_1", personId: nil, displayName: nil)
        try store.updateMeetingTitle(id: gone.id, title: "架空の消えた会議")
        let server = Server { request in
            if request.path == "/v1/meeting-edits" { return Self.emptyFeed }
            if request.path == "/v1/recordings/rec-gone" { return Self.reply(["error": "not_found"], status: 404) }
            return Self.recordingReply
        }
        let report = await CloudEditSync.sync(client: server.client(), store: store)
        #expect(report.pushed == 3 && report.dropped == 1 && report.interruption == nil)
        #expect(try store.pendingCloudEditPushes().isEmpty)
        let body = try #require(server.patches.first { $0.path == "/v1/recordings/rec-1" }?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["title"] as? String == "架空の定例（Mac で直した）")
        // 名前を消したものは空で送る
        #expect((json["speaker_names"] as? [String: String]) == ["spk_0": "架空の佐藤", "spk_1": ""])
        #expect(server.patches.count == 2)
    }

    @Test("回線・サーバーの誤りでは送るのをやめ、列に残す（次の同期で送る。読む前にやめる）")
    func pushInterrupted() async throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1", platform: .iphone)
        try store.updateMeetingTitle(id: imported.id, title: "架空の定例（Mac で直した）")
        let server = Server { _ in Self.reply(["error": "internal"], status: 503) }
        let report = await CloudEditSync.sync(client: server.client(), store: store)
        #expect(report.pushed == 0 && report.interruption != nil)
        #expect(try store.pendingCloudEditPushes().count == 1)
        #expect(server.feedQueries.isEmpty)
    }

    @Test("当てる: 番号の順に読んで題名と話者の名前を手元に当て、読んだところを覚える。同期を切っていても Mac の会議に当てる。送る列には入れない")
    func pull() async throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1", platform: .iphone)
        // 同期の記録のない Mac の会議（同期を切っている）にも当てる
        let mac = try meeting(store, title: "架空の Mac の定例")
        let server = Server { request in
            guard request.path == "/v1/meeting-edits" else { return Self.reply([:], status: 404) }
            if request.query?.contains("after=0") == true {
                return Self.reply(["edits": [
                    Self.edit("rec-1", field: "title", value: "架空の定例（iPhone で直した）", seq: 4),
                    Self.edit("rec-1", field: "speaker", label: "spk_0", value: "架空の佐藤", seq: 5),
                    Self.edit("srv-meeting", kind: "meeting", meetingId: mac.id, field: "title", value: "架空の Mac の定例（iPhone で直した）", seq: 6),
                    Self.edit("srv-meeting", kind: "meeting", meetingId: mac.id, field: "speaker", label: "spk_1", value: "架空の鈴木", seq: 7),
                    // 手元にない会議・話者、知らない欄は飛ばす
                    Self.edit("rec-unknown", field: "title", value: "架空の知らない会議", seq: 8),
                    Self.edit("rec-1", field: "speaker", label: "spk_9", value: "架空の誰か", seq: 9),
                    Self.edit("rec-1", field: "summary", value: "x", seq: 10),
                ], "next": 11, "more": false])
            }
            return Self.reply(["edits": [], "next": 11, "more": false])
        }
        let client = server.client()
        let first = await CloudEditSync.sync(client: client, store: store)
        #expect(first.applied == 4 && first.interruption == nil)
        #expect(Set(first.changedMeetings) == [imported.id, mac.id])
        #expect(try store.meeting(id: imported.id)?.title == "架空の定例（iPhone で直した）")
        #expect(try store.meeting(id: mac.id)?.title == "架空の Mac の定例（iPhone で直した）")
        #expect(try speaker(store, imported.id, "spk_0").displayName == "架空の佐藤")
        #expect(try speaker(store, mac.id, "spk_1").displayName == "架空の鈴木")
        #expect(try store.pendingCloudEditPushes().isEmpty)
        #expect(CloudEditSync.editsSeen(client: client, store: store) == 11)
        let second = await CloudEditSync.sync(client: client, store: store)
        #expect(second.applied == 0)
        #expect(server.feedQueries == ["after=0", "after=11"])
        // ログインし直したら（印が変わったら）はじめから読む。ログインしていなければ edits_seen は付けない
        #expect(CloudEditSync.editsSeen(client: server.client(token: "another-token"), store: store) == 0)
        #expect(CloudEditSync.editsSeen(client: server.client(token: ""), store: store) == nil)
    }

    @Test("話者の名前: 人物と違う名前なら人物の結び付きを外し、同じ名前なら残す。空なら名前を消す")
    func speakerNamesAndPeople() throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1", platform: .iphone)
        let person = try store.findOrCreatePerson(name: "架空の田中", email: nil)
        try store.replaceSpeakers(meetingId: imported.id, with: [
            SpeakerRecord(meetingId: imported.id, clusterLabel: "spk_0", personId: person.id, displayName: "架空の田中"),
            SpeakerRecord(meetingId: imported.id, clusterLabel: "spk_1", personId: person.id, displayName: "架空の田中"),
        ])
        #expect(try store.applyCloudMeetingEdit(meetingId: imported.id, field: CloudEditField.speaker("spk_0"), value: "架空の田中") == .unchanged)
        #expect(try speaker(store, imported.id, "spk_0").personId == person.id)
        #expect(try store.applyCloudMeetingEdit(meetingId: imported.id, field: CloudEditField.speaker("spk_0"), value: "架空の佐藤") == .applied)
        let renamed = try speaker(store, imported.id, "spk_0")
        #expect(renamed.displayName == "架空の佐藤" && renamed.personId == nil)
        #expect(try store.applyCloudMeetingEdit(meetingId: imported.id, field: CloudEditField.speaker("spk_1"), value: "  ") == .applied)
        let cleared = try speaker(store, imported.id, "spk_1")
        #expect(cleared.displayName == nil && cleared.personId == nil)
        #expect(try store.pendingCloudEditPushes().isEmpty)
    }

    @Test("この Mac で文字起こしし直した取り込んだ会議（話者のラベルがサーバーと合わない）は、話者の名前を送らず当てない。題名は合わせる")
    func retranscribedImportKeepsSpeakersLocal() throws {
        let store = try Store.inMemory()
        let redone = try meeting(store, cloudRecordingId: "rec-1", platform: .iphone, cloudProcessed: false)
        try store.assignSpeaker(meetingId: redone.id, clusterLabel: "spk_0", personId: nil, displayName: "架空の佐藤")
        try store.updateMeetingTitle(id: redone.id, title: "架空の定例（Mac で直した）")
        #expect(try store.pendingCloudEditPushes().map(\.field) == [CloudEditField.title])
        #expect(try store.applyCloudMeetingEdit(meetingId: redone.id, field: CloudEditField.speaker("spk_1"), value: "架空の鈴木") == .unchanged)
        #expect(try speaker(store, redone.id, "spk_1").displayName == nil)
        try store.finishCloudEditPush(try #require(try store.pendingCloudEditPushes().first))
        #expect(try store.applyCloudMeetingEdit(meetingId: redone.id, field: CloudEditField.title, value: "架空の定例（iPhone で直した）") == .applied)
    }

    @Test("空の題名: 取り込んだ会議は録った機器の仮の題名にし、Mac の会議は変えない")
    func emptyTitle() throws {
        let store = try Store.inMemory()
        let watch = try meeting(store, cloudRecordingId: "rec-1", platform: .watch)
        let mac = try meeting(store, title: "架空の Mac の定例")
        #expect(try store.applyCloudMeetingEdit(meetingId: watch.id, field: CloudEditField.title, value: nil) == .applied)
        #expect(try store.meeting(id: watch.id)?.title == "Apple Watch の録音")
        #expect(try store.applyCloudMeetingEdit(meetingId: mac.id, field: CloudEditField.title, value: "") == .unchanged)
        #expect(try store.meeting(id: mac.id)?.title == "架空の Mac の定例")
    }

    @Test("まだ送っていない手元の直しがある欄には、サーバーの直しを当てない（手元のほうが新しい）")
    func pendingWins() throws {
        let store = try Store.inMemory()
        let imported = try meeting(store, cloudRecordingId: "rec-1", platform: .iphone)
        try store.updateMeetingTitle(id: imported.id, title: "架空の定例（Mac で直した）")
        #expect(try store.applyCloudMeetingEdit(meetingId: imported.id, field: CloudEditField.title, value: "架空の定例（iPhone で直した）") == .unchanged)
        #expect(try store.meeting(id: imported.id)?.title == "架空の定例（Mac で直した）")
        #expect(try store.applyCloudMeetingEdit(meetingId: imported.id, field: CloudEditField.speaker("spk_0"), value: "架空の佐藤") == .applied)
    }

    @Test("後処理の途中の取り込んだ会議（話者がまだない）の話者の直しは、読んだところをその直前で止め、話者ができてから当てる")
    func holdsUntilSpeakersExist() async throws {
        let store = try Store.inMemory()
        let pending = try meeting(store, cloudRecordingId: "rec-new", platform: .iphone, status: .finalizing, speakers: false)
        let other = try meeting(store, cloudRecordingId: "rec-1", platform: .iphone)
        let server = Server { request in
            guard request.path == "/v1/meeting-edits" else { return Self.reply([:], status: 404) }
            let all = [
                Self.edit("rec-1", field: "title", value: "架空の定例（直した）", seq: 3),
                Self.edit("rec-new", field: "speaker", label: "spk_0", value: "架空の佐藤", seq: 5),
                Self.edit("rec-1", field: "speaker", label: "spk_1", value: "架空の鈴木", seq: 7),
            ]
            let after = request.query?.contains("after=3") == true ? 3 : (request.query?.contains("after=7") == true ? 7 : 0)
            return Self.reply(["edits": all.filter { (($0["seq"] as? Int) ?? 0) > after }, "next": 7, "more": false])
        }
        let client = server.client()
        let first = await CloudEditSync.sync(client: client, store: store)
        #expect(first.applied == 2)
        #expect(try store.meeting(id: other.id)?.title == "架空の定例（直した）")
        // 後処理が終わって話者ができた
        try store.replaceSpeakers(meetingId: pending.id, with: [SpeakerRecord(meetingId: pending.id, clusterLabel: "spk_0", personId: nil, displayName: nil)])
        try store.setMeetingStatus(id: pending.id, status: .done)
        let second = await CloudEditSync.sync(client: client, store: store)
        #expect(second.applied == 1 && second.changedMeetings == [pending.id])
        #expect(try speaker(store, pending.id, "spk_0").displayName == "架空の佐藤")
        _ = await CloudEditSync.sync(client: client, store: store)
        #expect(server.feedQueries == ["after=0", "after=3", "after=7"])
    }

    @Test("同期した会議の上げ直しに edits_seen を付ける（ないときは送らない）")
    func uploadCarriesEditsSeen() throws {
        let document = TranscriptDocument(meeting: .init(id: "m1", title: "架空の定例", startedAt: nil, durationSeconds: 60, sourceDirectory: nil),
                                          provider: "test", language: "ja", speakers: [], segments: [])
        var upload = MinutesCloudMeetingUpload(title: "架空の定例", startedAt: Date(timeIntervalSince1970: 1_790_000_000), timeZone: "Asia/Tokyo",
                                               language: "ja", durationSeconds: 60, transcript: document, summary: nil)
        let without = try JSONSerialization.jsonObject(with: JSONCoding.encoder(pretty: false).encode(upload)) as? [String: Any]
        #expect(without?["edits_seen"] == nil)
        upload.editsSeen = 42
        let with = try JSONSerialization.jsonObject(with: JSONCoding.encoder(pretty: false).encode(upload)) as? [String: Any]
        #expect(with?["edits_seen"] as? Int == 42)
    }
}
