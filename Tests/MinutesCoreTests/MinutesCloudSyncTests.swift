import Foundation
@testable import MinutesCore
import Synchronization
import Testing

/// Minutes クラウドへの会議の同期（P7）。会議と人名は架空。サーバーはテスト用の URLProtocol。
@Suite("Minutes クラウドへの会議の同期")
struct MinutesCloudSyncTests {
    typealias Answer = (status: Int, headers: [String: String], body: Data)

    static func reply(_ object: Any, status: Int = 200) -> Answer {
        (status, ["content-type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }

    static func recordingReply(_ id: String = "srv-1") -> Answer {
        reply(["recording": ["id": id, "client_id": "meeting:x", "status": "done", "kind": "meeting", "source": "mac"]])
    }

    /// 自分（me）・相手（spk_0、名前あり）・背景の声（spk_1、外した）の 10 分の会議。やることの 1 つは済み
    func seed(_ store: Store, cloudRecordingId: String? = nil) throws -> MeetingRecord {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let meeting = try store.createMeeting(MeetingRecord(title: "架空の定例", startedAt: started, endedAt: started.addingTimeInterval(600), privacyMode: .cloudOk, status: .done,
                                                            cloudRecordingId: cloudRecordingId))
        let speakers = [
            SpeakerRecord(meetingId: meeting.id, clusterLabel: "me"),
            SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_0", displayName: "架空の山田"),
            SpeakerRecord(meetingId: meeting.id, clusterLabel: "spk_1", excluded: true),
        ]
        let segments = [
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 2, clusterLabel: "me", text: "架空のはじめの発言"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 3, tEnd: 5, clusterLabel: "spk_0", text: "架空の資料を直します"),
            SegmentRecord(meetingId: meeting.id, source: .final, tStart: 6, tEnd: 8, clusterLabel: "spk_1", text: "架空の背景の声"),
        ]
        try store.saveTranscript(meetingId: meeting.id, segments: segments, speakers: speakers)
        let summary = MinutesSummary(summaryMd: "- 架空の要約", decisions: [.init(text: "架空の決定", evidence: [1])],
                                     actionItems: [.init(text: "架空の日程を送る", owner: "me", kind: .ownCommitment, due: nil, evidence: [], done: true),
                                                   .init(text: "架空の資料を直す", owner: "架空の山田", kind: .theirTask, due: "2026-12-04", evidence: [2])],
                                     openQuestions: [], keytermsLearned: [])
        try store.upsertNotes(NotesRecord(meetingId: meeting.id, summary: summary, model: "codex/test", userNotesMd: "架空のメモ（送らない）"))
        return try #require(try store.meeting(id: meeting.id))
    }

    func pipeline(_ store: Store, base: URL, uploads: Bool = true, export: URL) -> PostProcessPipeline {
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" })
        let providers = PipelineProviders(cloud: nil, local: LocalTranscriber(), summarizer: nil, exportDirectory: export,
                                          syncTargets: [MinutesCloudSyncTarget(client: client, uploads: uploads, timeZone: TimeZone(identifier: "Asia/Tokyo")!)])
        return PostProcessPipeline(store: store, providers: providers)
    }

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func latestStatus(_ store: Store, _ meetingId: String) throws -> String? {
        try store.exportLog(meetingId: meetingId).last(where: { $0.target == MinutesCloudSyncTarget.targetID })?.status
    }

    @Test("送る本文: 話者はラベルで指し、名前は speakers に置く。外した話者の発言とメモは送らない。やることの済みは送る")
    func payload() throws {
        let store = try Store.inMemory()
        let meeting = try seed(store)
        let input = try store.withCloudExport(meetingId: meeting.id) { $0 }
        let upload = MinutesCloudSyncTarget.payload(input, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(upload.title == "架空の定例" && upload.language == "ja" && upload.timeZone == "Asia/Tokyo" && upload.durationSeconds == 600)
        #expect(upload.transcript.speakers.map(\.label) == ["me", "spk_0"])
        #expect(upload.transcript.speakers.map(\.name) == [nil, "架空の山田"])
        #expect(upload.transcript.segments.map(\.speaker) == ["me", "spk_0"])
        #expect(upload.transcript.segments.map(\.track) == [TrackMerger.micTrack, TrackMerger.systemTrack])
        #expect(upload.summary?.actionItems.first?.done == true)
        let json = String(decoding: try JSONCoding.encoder(pretty: false).encode(upload), as: UTF8.self)
        #expect(json.contains("\"started_at\"") && json.contains("\"duration_seconds\":600"))
        #expect(!json.contains("架空の背景の声") && !json.contains("架空のメモ") && !json.contains("source_directory"))
    }

    @Test("書き出しで送る（PUT /v1/meetings/<会議の ID>）。取り込んだ会議と、同期を切っているときは送らない")
    func uploadOnExport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Mutex<[StubURLProtocol.Request]>([])
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append(request) }
            return Self.recordingReply()
        }
        let store = try Store.inMemory()
        let meeting = try seed(store)
        let imported = try seed(store, cloudRecordingId: "rec-from-iphone")
        try await pipeline(store, base: base, export: root).refreshExport(meetingId: meeting.id)
        try await pipeline(store, base: base, export: root).refreshExport(meetingId: imported.id)
        let off = try seed(store)
        try await pipeline(store, base: base, uploads: false, export: root).refreshExport(meetingId: off.id)
        let requests = seen.withLock { $0 }
        #expect(requests.map { "\($0.method) \($0.path)" } == ["PUT /v1/meetings/\(meeting.id)"])
        let body = try #require(requests.first?.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let transcript = try #require(body["transcript"] as? [String: Any])
        #expect((transcript["speakers"] as? [[String: Any]])?.compactMap { $0["label"] as? String } == ["me", "spk_0"])
        #expect(try latestStatus(store, meeting.id) == "ok")
        #expect(try latestStatus(store, imported.id) == nil && latestStatus(store, off.id) == nil)
    }

    @Test("消した会議はサーバーからも消す（消せなければ待ち、あとで消す）。送ったことのない会議はサーバーに聞かない")
    func removeDeleted() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let deleteAnswers = Mutex<[Int]>([503, 204])
        let seen = Mutex<[String]>([])
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append("\(request.method) \(request.path)") }
            if request.method == "DELETE" {
                let status = deleteAnswers.withLock { $0.isEmpty ? 404 : $0.removeFirst() }
                return status == 204 ? (204, [:], Data()) : Self.reply(["error": "unavailable"], status: status)
            }
            return Self.recordingReply()
        }
        let store = try Store.inMemory()
        let synced = try seed(store)
        let never = try seed(store)
        let pipe = pipeline(store, base: base, export: root)
        try await pipe.refreshExport(meetingId: synced.id)
        try store.deleteMeeting(id: synced.id)
        try store.deleteMeeting(id: never.id)
        #expect(try store.pendingRemovals().map(\.meetingId) == [synced.id])
        _ = await pipe.retryPendingRemovals()
        #expect(try store.pendingRemovals().map(\.meetingId) == [synced.id])
        _ = await pipe.retryPendingRemovals()
        #expect(try store.pendingRemovals().isEmpty)
        #expect(try latestStatus(store, synced.id) == ExportStatus.removed.rawValue)
        #expect(seen.withLock { $0 }.filter { $0.hasPrefix("DELETE") } == ["DELETE /v1/meetings/\(synced.id)", "DELETE /v1/meetings/\(synced.id)"])
    }

    @Test("再送は、有料でない・ログイン切れ・混雑なら、その回の残りを送らない（会議ごとの誤りでは続ける）")
    func haltRetries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let puts = Mutex(0)
        let base = StubURLProtocol.host { request in
            puts.withLock { $0 += 1 }
            return Self.reply(["error": "no_plan"], status: 402)
        }
        let store = try Store.inMemory()
        let ids = try (0..<3).map { _ in try seed(store).id }
        try store.queueExports(meetingIds: ids, target: MinutesCloudSyncTarget.targetID)
        _ = await pipeline(store, base: base, export: root).retryPendingExports()
        #expect(puts.withLock { $0 } == 1)
        #expect(try store.pendingExports().filter { $0.target == MinutesCloudSyncTarget.targetID }.count == 3)

        let target = MinutesCloudSyncTarget(client: MinutesCloudClient(baseURL: base, token: { nil }), uploads: true)
        #expect(target.haltsRetries(MinutesCloudError.http(status: 402, code: "no_plan", requestID: nil)))
        #expect(target.haltsRetries(MinutesCloudError.notSignedIn) && target.haltsRetries(URLError(.notConnectedToInternet)))
        #expect(!target.haltsRetries(MinutesCloudError.http(status: 400, code: "bad_meeting", requestID: nil)))
    }

    @Test("送り直しても通らない会議（400・413）は failed にして待たせない。404（同期のないサーバー）はその回の残りを送らない")
    func permanentFailures() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let puts = Mutex(0)
        let base = StubURLProtocol.host { _ in
            puts.withLock { $0 += 1 }
            return Self.reply(["error": "bad_meeting", "message": "transcript.segments"], status: 400)
        }
        let store = try Store.inMemory()
        let meeting = try seed(store)
        let pipe = pipeline(store, base: base, export: root)
        try await pipe.refreshExport(meetingId: meeting.id)
        #expect(try latestStatus(store, meeting.id) == ExportStatus.failed.rawValue)
        _ = await pipe.retryPendingExports()
        #expect(puts.withLock { $0 } == 1)

        let target = MinutesCloudSyncTarget(client: MinutesCloudClient(baseURL: base, token: { nil }), uploads: true)
        #expect(target.isPermanentFailure(MinutesCloudError.http(status: 413, code: "too_large", requestID: nil)))
        #expect(!target.isPermanentFailure(MinutesCloudError.http(status: 503, code: nil, requestID: nil)))
        #expect(target.haltsRetries(MinutesCloudError.http(status: 404, code: "not_found", requestID: nil)))
    }

    @Test("Mac の取り込みは iPhone・Watch の録音だけを読む（scope=mobile。同期した会議や Mac の録音に押し出されない）")
    func importReadsMobileScope() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queries = Mutex<[String]>([])
        let base = StubURLProtocol.host { request in
            queries.withLock { $0.append("\(request.path)?\(request.query ?? "")") }
            return Self.reply(["recordings": []])
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" })
        _ = try await CloudMeetingImport.pull(client: client, store: try Store.inMemory(), audioRoot: root)
        #expect(queries.withLock { $0 } == ["/v1/recordings?scope=mobile"])
    }

    @Test("ローカルのみにすると、サーバーから消す（送ったことのある会議だけ）")
    func localOnlyRemoves() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Mutex<[String]>([])
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append("\(request.method) \(request.path)") }
            return request.method == "DELETE" ? (204, [:], Data()) : Self.recordingReply()
        }
        let store = try Store.inMemory()
        let synced = try seed(store)
        let never = try seed(store)
        let pipe = pipeline(store, base: base, export: root)
        try await pipe.refreshExport(meetingId: synced.id)
        for meeting in [synced, never] {
            var restricted = try #require(try store.meeting(id: meeting.id))
            restricted.privacy = .localOnly
            try store.updateMeeting(restricted)
            _ = try await pipe.removeExportedFiles(meetingId: meeting.id)
        }
        #expect(seen.withLock { $0 }.filter { $0.hasPrefix("DELETE") } == ["DELETE /v1/meetings/\(synced.id)"])
        #expect(try latestStatus(store, synced.id) == ExportStatus.removed.rawValue)
    }

    @Test("送れなかった会議を数え、待ちに戻して送り直す（消した・ローカルのみにした会議は数えない。同期を切っているときは戻さない）")
    func failedAreRequeued() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accepts = Mutex(false)
        let base = StubURLProtocol.host { _ in
            accepts.withLock { $0 } ? Self.recordingReply() : Self.reply(["error": "bad_meeting", "message": "transcript.provider"], status: 400)
        }
        let store = try Store.inMemory()
        let failed = try seed(store)
        let deleted = try seed(store)
        var local = try seed(store)
        let pipe = pipeline(store, base: base, export: root)
        for meeting in [failed, deleted, local] { try await pipe.refreshExport(meetingId: meeting.id) }
        try store.deleteMeeting(id: deleted.id)
        local.privacy = .localOnly
        try store.updateMeeting(local)
        #expect(try store.failedCloudSyncMeetingIds() == [failed.id])

        // 同期を切っている・同期先がないときは戻さない
        #expect(pipeline(store, base: base, uploads: false, export: root).requeueFailedCloudSync() == nil)
        let noTarget = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: LocalTranscriber(), summarizer: nil, exportDirectory: root))
        #expect(noTarget.requeueFailedCloudSync() == nil)
        #expect(try store.failedCloudSyncMeetingIds() == [failed.id])

        // 通らないままなら、送り直してもまた failed（数に戻る）
        #expect(pipe.requeueFailedCloudSync() == 1)
        #expect(try store.failedCloudSyncMeetingIds().isEmpty)
        _ = await pipe.retryPendingExports()
        #expect(try store.failedCloudSyncMeetingIds() == [failed.id])

        // サーバーが受けるようになったら届く
        accepts.withLock { $0 = true }
        #expect(pipe.requeueFailedCloudSync() == 1)
        _ = await pipe.retryPendingExports()
        #expect(try latestStatus(store, failed.id) == ExportStatus.ok.rawValue)
        #expect(try store.failedCloudSyncMeetingIds().isEmpty)
        #expect(pipe.requeueFailedCloudSync() == 0)
    }

    @Test("同期を入れたときに送る会議: 終わった・クラウド OK・取り込んだ会議でない（新しい順）")
    func eligible() throws {
        let store = try Store.inMemory()
        let a = try seed(store)
        _ = try seed(store, cloudRecordingId: "rec-iphone")
        var local = try seed(store)
        local.privacy = .localOnly
        try store.updateMeeting(local)
        #expect(try store.meetingIdsForCloudSync() == [a.id])
    }

    @Test("消す要求の 404 は、もう消えたものとして扱う（作り直したアカウント・すでに消えた会議）。その回の残りも消す。ローカルのみにしたときも同じ")
    func removeTreatsNotFoundAsRemoved() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = Mutex<[String]>([])
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append("\(request.method) \(request.path)") }
            return request.method == "DELETE" ? Self.reply(["error": "not_found"], status: 404) : Self.recordingReply()
        }
        let store = try Store.inMemory()
        let first = try seed(store)
        let second = try seed(store)
        var local = try seed(store)
        let pipe = pipeline(store, base: base, export: root)
        for meeting in [first, second, local] { try await pipe.refreshExport(meetingId: meeting.id) }
        try store.deleteMeeting(id: first.id)
        try store.deleteMeeting(id: second.id)
        #expect(Set(try store.pendingRemovals().map(\.meetingId)) == [first.id, second.id])
        _ = await pipe.retryPendingRemovals()
        #expect(try store.pendingRemovals().isEmpty)
        #expect(try latestStatus(store, first.id) == ExportStatus.removed.rawValue)
        #expect(try latestStatus(store, second.id) == ExportStatus.removed.rawValue)

        local.privacy = .localOnly
        try store.updateMeeting(local)
        _ = try await pipe.removeExportedFiles(meetingId: local.id)
        #expect(try latestStatus(store, local.id) == ExportStatus.removed.rawValue)
        #expect(seen.withLock { $0 }.filter { $0.hasPrefix("DELETE") }.count == 3)
    }

    @Test("ログインし直したら、送った会議も含めて同期する会議をまとめて送り直す（取り込んだ会議は送らない。同期を切っている・同期先がないときは戻さない）")
    func requeueAllAfterSignIn() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let puts = Mutex<[String]>([])
        let base = StubURLProtocol.host { request in
            if request.method == "PUT" { puts.withLock { $0.append(request.path) } }
            return Self.recordingReply()
        }
        let store = try Store.inMemory()
        let a = try seed(store)
        let b = try seed(store)
        _ = try seed(store, cloudRecordingId: "rec-iphone")
        let pipe = pipeline(store, base: base, export: root)
        for meeting in [a, b] { try await pipe.refreshExport(meetingId: meeting.id) }
        #expect(puts.withLock { $0 }.count == 2)

        #expect(pipeline(store, base: base, uploads: false, export: root).requeueAllForCloudSync() == nil)
        let noTarget = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: LocalTranscriber(), summarizer: nil, exportDirectory: root))
        #expect(noTarget.requeueAllForCloudSync() == nil)
        #expect(try store.pendingExports().filter { $0.target == MinutesCloudSyncTarget.targetID }.isEmpty)

        #expect(pipe.requeueAllForCloudSync() == 2)
        _ = await pipe.retryPendingExports()
        let resent = puts.withLock { $0 }.dropFirst(2)
        #expect(Set(resent) == ["/v1/meetings/\(a.id)", "/v1/meetings/\(b.id)"])
        #expect(try latestStatus(store, a.id) == ExportStatus.ok.rawValue && latestStatus(store, b.id) == ExportStatus.ok.rawValue)
        #expect(try store.pendingExports().filter { $0.target == MinutesCloudSyncTarget.targetID }.isEmpty)
    }

    @Test("一覧の同期の印: 同期を入れていてログインしているときだけ。送っている最中・送れた・待ち・送れなかった・取り込んだ会議。ローカルのみと終わっていない会議には出さない")
    func syncMarks() throws {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let done = MeetingRecord(title: "架空の定例", startedAt: started, endedAt: started.addingTimeInterval(600), privacyMode: .cloudOk, status: .done)
        let at = started.addingTimeInterval(700)
        func record(_ status: ExportStatus) -> CloudSyncRecord { CloudSyncRecord(status: status, at: at) }

        #expect(CloudSyncMark.make(meeting: done, record: record(.ok), isSyncing: false, enabled: false) == nil)
        #expect(CloudSyncMark.make(meeting: done, record: record(.ok), isSyncing: false, enabled: true) == .synced(at))
        #expect(CloudSyncMark.make(meeting: done, record: record(.pending), isSyncing: false, enabled: true) == .waiting)
        #expect(CloudSyncMark.make(meeting: done, record: record(.failed), isSyncing: false, enabled: true) == .failed)
        #expect(CloudSyncMark.make(meeting: done, record: record(.pending), isSyncing: true, enabled: true) == .syncing)
        #expect(CloudSyncMark.make(meeting: done, record: record(.removed), isSyncing: false, enabled: true) == nil)
        #expect(CloudSyncMark.make(meeting: done, record: nil, isSyncing: false, enabled: true) == nil)

        let local = MeetingRecord(title: "架空の相談", startedAt: started, endedAt: started.addingTimeInterval(600), privacyMode: .localOnly, status: .done)
        #expect(CloudSyncMark.make(meeting: local, record: record(.ok), isSyncing: false, enabled: true) == nil)
        let unfinished = MeetingRecord(title: "架空の録音中", startedAt: started, privacyMode: .cloudOk, status: .recording)
        #expect(CloudSyncMark.make(meeting: unfinished, record: record(.ok), isSyncing: false, enabled: true) == nil)
        let imported = MeetingRecord(title: "架空の対面", startedAt: started, endedAt: started.addingTimeInterval(600), privacyMode: .cloudOk, status: .done,
                                     cloudRecordingId: "rec-iphone")
        #expect(CloudSyncMark.make(meeting: imported, record: nil, isSyncing: false, enabled: true) == .synced(nil))
    }

    @Test("会議ごとの最新の記録（Minutes クラウドだけ。書き出しの記録は混ぜない）と、送っているあいだの知らせ")
    func syncRecordsAndActivity() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accepts = Mutex(false)
        let base = StubURLProtocol.host { _ in
            accepts.withLock { $0 } ? Self.recordingReply() : Self.reply(["error": "unavailable"], status: 503)
        }
        let store = try Store.inMemory()
        let meeting = try seed(store)
        let activity = Mutex<[String]>([])
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" })
        let providers = PipelineProviders(cloud: nil, local: LocalTranscriber(), summarizer: nil, exportDirectory: root,
                                          syncTargets: [MinutesCloudSyncTarget(client: client, uploads: true, timeZone: TimeZone(identifier: "Asia/Tokyo")!)],
                                          onSyncActivity: { id, target, active in activity.withLock { $0.append("\(id)/\(target)/\(active)") } })
        let pipe = PostProcessPipeline(store: store, providers: providers)

        try await pipe.refreshExport(meetingId: meeting.id)
        #expect(try store.cloudSyncRecords()[meeting.id]?.status == .pending)
        accepts.withLock { $0 = true }
        _ = await pipe.retryPendingExports()
        let records = try store.cloudSyncRecords()
        #expect(records.count == 1 && records[meeting.id]?.status == .ok)
        let target = MinutesCloudSyncTarget.targetID
        #expect(activity.withLock { $0 } == ["\(meeting.id)/\(target)/true", "\(meeting.id)/\(target)/false",
                                              "\(meeting.id)/\(target)/true", "\(meeting.id)/\(target)/false"])
    }
}
