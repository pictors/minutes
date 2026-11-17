import Foundation
import MinutesCore
import Testing

@Suite("MCP サーバー（読み取り）")
struct MCPServerTests {
    /// 架空の会議を 3 つ作る: 終わった会議（要約あり）、ローカル専用の会議、そのあとの録音中の会議。
    struct Fixture {
        let store: Store
        let server: MCPServer<MinutesMCPHandler>
        let done: MeetingRecord
        let localOnly: MeetingRecord
        let recording: MeetingRecord
        let segmentIds: [Int64]
    }

    func makeFixture() throws -> Fixture {
        let store = try Store.inMemory()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let done = try store.createMeeting(MeetingRecord(
            title: "架空プロジェクト定例", startedAt: base, endedAt: base.addingTimeInterval(1800), platform: .meet,
            attendees: [Attendee(name: "山田", email: "yamada@example.com")], privacyMode: .cloudOk, status: .done, tags: ["定例"]
        ))
        try store.saveTranscript(meetingId: done.id, segments: [
            SegmentRecord(meetingId: done.id, source: .final, tStart: 1, tEnd: 4, clusterLabel: "me", text: "見積もりは金曜までに送ります"),
            SegmentRecord(meetingId: done.id, source: .final, tStart: 5, tEnd: 9, clusterLabel: "spk_0", text: "では仕様書のレビューはこちらで進めます"),
            SegmentRecord(meetingId: done.id, source: .final, tStart: 10, tEnd: 12, clusterLabel: "spk_1", text: "後ろの席の雑談"),
            SegmentRecord(meetingId: done.id, source: .final, tStart: 13, tEnd: 15, clusterLabel: "spk_0", text: "次回は来週の火曜で"),
        ], speakers: [
            SpeakerRecord(meetingId: done.id, clusterLabel: "me"),
            SpeakerRecord(meetingId: done.id, clusterLabel: "spk_0", displayName: "山田"),
            SpeakerRecord(meetingId: done.id, clusterLabel: "spk_1", displayName: "背景", excluded: true),
        ])
        let ids = try store.segments(meetingId: done.id, source: .final).compactMap(\.id)
        try store.upsertNotes(NotesRecord(meetingId: done.id, summary: MinutesSummary(
            summaryMd: "見積もりと仕様書のレビューについて話した。",
            decisions: [.init(text: "次回は来週火曜", evidence: [Int(ids[3])])],
            actionItems: [
                .init(text: "見積もりを送る", owner: "me", kind: .ownCommitment, due: "2027-01-15", evidence: [Int(ids[0])], id: "act-1"),
                .init(text: "仕様書をレビューする", owner: "山田", kind: .theirTask, due: nil, evidence: [Int(ids[1])], id: "act-2"),
            ],
            openQuestions: [], keytermsLearned: []
        ), model: "test"))

        let localOnly = try store.createMeeting(MeetingRecord(
            title: "内密の面談", startedAt: base.addingTimeInterval(3600), privacyMode: .localOnly, status: .done
        ))
        try store.saveTranscript(meetingId: localOnly.id, segments: [
            SegmentRecord(meetingId: localOnly.id, source: .final, tStart: 1, tEnd: 3, clusterLabel: "me", text: "見積もりの件は内密に"),
        ], speakers: [SpeakerRecord(meetingId: localOnly.id, clusterLabel: "me")])

        let recording = try store.createMeeting(MeetingRecord(
            title: "録音中の会議", startedAt: base.addingTimeInterval(7200), privacyMode: .cloudOk, status: .recording
        ))
        let handler = MinutesMCPHandler(store: store, serverVersion: "test", exportDirectory: nil, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        return Fixture(store: store, server: MCPServer(handler: handler), done: done, localOnly: localOnly, recording: recording, segmentIds: ids)
    }

    func send(_ server: MCPServer<MinutesMCPHandler>, _ json: String) throws -> JSONValue {
        let line = try #require(server.handle(line: json))
        #expect(!line.contains("\n"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    /// tools/call の本文と isError。
    func call(_ server: MCPServer<MinutesMCPHandler>, _ tool: String, _ arguments: String = "{}") throws -> (text: String, isError: Bool) {
        let response = try send(server, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#)
        let result = try #require(response["result"])
        guard case let .array(content)? = result["content"] else { Issue.record("content がない"); return ("", true) }
        return (content.first?["text"]?.stringValue ?? "", result["isError"]?.boolValue ?? false)
    }

    @Test("initialize・通知・不明なメソッド・壊れた JSON")
    func protocolBasics() throws {
        let fixture = try makeFixture()
        let initialize = try send(fixture.server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(initialize["id"] == 1)
        #expect(initialize["result"]?["protocolVersion"] == "2025-03-26")
        #expect(initialize["result"]?["serverInfo"]?["name"] == "minutes")
        #expect(initialize["result"]?["capabilities"]?["tools"] != nil)
        // 知らない版を求められたら、対応する最新の版を返す
        let future = try send(fixture.server, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        #expect(future["id"] == "a")
        #expect(future["result"]?["protocolVersion"]?.stringValue == MCPServer<MinutesMCPHandler>.supportedProtocolVersions[0])

        #expect(fixture.server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(fixture.server.handle(line: "") == nil)
        #expect(try send(fixture.server, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)["result"] == [:])
        #expect(try send(fixture.server, #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)["error"]?["code"] == -32601)
        #expect(try send(fixture.server, "{not json")["error"]?["code"] == -32700)
        #expect(try send(fixture.server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_everything"}}"#)["error"]?["code"] == -32602)
    }

    @Test("ツールは 4 つで、すべて読み取りだけ")
    func toolsList() throws {
        let fixture = try makeFixture()
        let response = try send(fixture.server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        guard case let .array(tools)? = response["result"]?["tools"] else { Issue.record("tools がない"); return }
        #expect(Set(tools.compactMap { $0["name"]?.stringValue }) == ["list_meetings", "get_meeting", "get_transcript", "search_meetings"])
        #expect(tools.allSatisfy { $0["annotations"]?["readOnlyHint"] == true })
        #expect(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" })
    }

    @Test("meeting_id を省くと、録音中を除いた直前の会議（ローカル専用は除く）")
    func latestMeeting() throws {
        let fixture = try makeFixture()
        let (text, isError) = try call(fixture.server, "get_meeting")
        #expect(!isError)
        #expect(text.contains("# 架空プロジェクト定例"))
        #expect(text.contains("ID: \(fixture.done.id)"))
        #expect(text.contains("Minutes で開く: minutes://meeting/\(fixture.done.id)"))
        #expect(text.contains("状態: 完了"))
        #expect(text.contains("参加者（カレンダー）: 山田 <yamada@example.com>"))
        #expect(text.contains("- [ ] 見積もりを送る"))
        #expect(text.contains("担当: 自分 / 種別: own_commitment（自分の約束） / 期限: 2027-01-15 / ID: act-1（根拠: #\(fixture.segmentIds[0])）"))
        #expect(text.contains("担当: 山田 / 種別: their_task（相手の宿題） / 期限: なし / ID: act-2"))
        #expect(text.contains("次回は来週火曜（根拠: #\(fixture.segmentIds[3])）"))
        // 全文は既定では付けず、件数だけ（除外した話者の発言は数えない）
        #expect(text.contains("発言 3 件"))
        #expect(!text.contains("仕様書のレビューはこちらで"))
        #expect(!text.contains("内密"))
    }

    @Test("全文: 話者名・発言 ID つき、除外した話者は出さず、start と limit で分ける")
    func transcript() throws {
        let fixture = try makeFixture()
        let full = try call(fixture.server, "get_meeting", #"{"meeting_id":"\#(fixture.done.id)","include_transcript":true}"#).text
        #expect(full.contains("[00:00:01] #\(fixture.segmentIds[0]) 自分: 見積もりは金曜までに送ります"))
        #expect(full.contains("#\(fixture.segmentIds[1]) 山田: では仕様書のレビューはこちらで進めます"))
        #expect(!full.contains("雑談"))

        let page = try call(fixture.server, "get_transcript", #"{"meeting_id":"\#(fixture.done.id)","start":1,"limit":1}"#).text
        #expect(page.contains("発言 3 件のうち 2〜2 件目（続きは start: 2）"))
        #expect(page.contains("山田: では仕様書のレビュー"))
        #expect(!page.contains("見積もりは金曜"))
        #expect(try call(fixture.server, "get_transcript", #"{"meeting_id":"\#(fixture.done.id)","start":99}"#).isError)
    }

    @Test("ローカル専用の会議は、ID を指定しても一覧・検索でも出さない")
    func localOnlyIsHidden() throws {
        let fixture = try makeFixture()
        let direct = try call(fixture.server, "get_meeting", #"{"meeting_id":"\#(fixture.localOnly.id)"}"#)
        #expect(direct.isError)
        #expect(direct.text.contains("ローカル専用"))
        #expect(!direct.text.contains("内密"))
        #expect(try call(fixture.server, "get_transcript", #"{"meeting_id":"\#(fixture.localOnly.id)"}"#).isError)

        let list = try call(fixture.server, "list_meetings").text
        #expect(list.contains("架空プロジェクト定例"))
        #expect(list.contains("録音中の会議"))
        #expect(!list.contains("内密"))

        let search = try call(fixture.server, "search_meetings", #"{"query":"見積もり"}"#).text
        #expect(search.contains("架空プロジェクト定例"))
        #expect(search.contains("> [00:00:01] #\(fixture.segmentIds[0]) 自分: 見積もりは金曜までに送ります"))
        #expect(!search.contains("内密"))
        #expect(try call(fixture.server, "get_meeting", #"{"meeting_id":"NOPE"}"#).isError)
    }

    @Test("一覧の期間とタグの絞り込み")
    func listFilters() throws {
        let fixture = try makeFixture()
        // 1_800_000_000 は 2027-01-15 17:00（日本時間）。録音中の会議は同じ日の 19:00
        let sameDay = try call(fixture.server, "list_meetings", #"{"since":"2027-01-15","until":"2027-01-15"}"#).text
        #expect(sameDay.contains("会議 2 件"))
        #expect(sameDay.contains("2027-01-15（金）17:00〜17:30（30 分）"))
        #expect(sameDay.contains("要約: 見積もりと仕様書のレビューについて話した。"))
        #expect(try call(fixture.server, "list_meetings", #"{"until":"2027-01-14"}"#).text == "条件に合う会議はありません。")
        let tagged = try call(fixture.server, "list_meetings", #"{"tag":"定例"}"#).text
        #expect(tagged.contains("会議 1 件"))
        #expect(try call(fixture.server, "list_meetings", #"{"since":"来週"}"#).isError)
    }

    @Test("後処理中の会議は、そのことを伝える")
    func processingMeeting() throws {
        let fixture = try makeFixture()
        try fixture.store.setMeetingStatus(id: fixture.recording.id, status: .finalizing)
        _ = try fixture.store.recordRun(meetingId: fixture.recording.id, step: PipelineStep.transcribeFinal.rawValue, status: .running)
        let text = try call(fixture.server, "get_meeting").text
        #expect(text.contains("# 録音中の会議"))
        #expect(text.contains("後処理中です（文字起こし）"))
        #expect(text.contains("（まだありません）"))
    }

    @Test("プロンプト: 議事録とタスク化")
    func prompts() throws {
        let fixture = try makeFixture()
        let list = try send(fixture.server, #"{"jsonrpc":"2.0","id":1,"method":"prompts/list"}"#)
        guard case let .array(prompts)? = list["result"]?["prompts"] else { Issue.record("prompts がない"); return }
        #expect(Set(prompts.compactMap { $0["name"]?.stringValue }) == ["minutes", "tasks"])

        let tasks = try send(fixture.server, #"{"jsonrpc":"2.0","id":2,"method":"prompts/get","params":{"name":"tasks","arguments":{"meeting_id":"M1","destination":"Backlog の TEST プロジェクト"}}}"#)
        guard case let .array(messages)? = tasks["result"]?["messages"] else { Issue.record("messages がない"); return }
        let text = try #require(messages.first?["content"]?["text"]?.stringValue)
        #expect(messages.first?["role"] == "user")
        #expect(text.contains("meeting_id: M1"))
        #expect(text.contains("Backlog の TEST プロジェクト に作る"))
        let minutes = try send(fixture.server, #"{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"minutes"}}"#)
        guard case let .array(minuteMessages)? = minutes["result"]?["messages"] else { Issue.record("messages がない"); return }
        #expect(minuteMessages.first?["content"]?["text"]?.stringValue?.contains("直前の会議") == true)
        #expect(try send(fixture.server, #"{"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{"name":"nope"}}"#)["error"]?["code"] == -32602)
    }

    @Test("読み取り専用で開いた DB は読めて、書けない")
    func readOnlyStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-mcp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("minutes.sqlite")
        #expect(throws: StoreError.self) { try Store.openReadOnly(at: url) }

        let writable = try Store.open(at: url)
        let meeting = try writable.createMeeting(MeetingRecord(title: "架空の会議", startedAt: Date(), privacyMode: .cloudOk, status: .done))
        let readOnly = try Store.openReadOnly(at: url)
        #expect(try readOnly.meeting(id: meeting.id)?.title == "架空の会議")
        #expect(throws: (any Error).self) { try readOnly.updateMeetingTitle(id: meeting.id, title: "書き換え") }
        // アプリ側の書き込みは、読み取り専用の接続からもすぐ見える
        try writable.updateMeetingTitle(id: meeting.id, title: "改名した会議")
        #expect(try readOnly.meeting(id: meeting.id)?.title == "改名した会議")
    }
}
