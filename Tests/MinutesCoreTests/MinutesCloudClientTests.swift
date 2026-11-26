import AVFoundation
import Foundation
@testable import MinutesCore
import Synchronization
import Testing

/// テスト用のサーバー（URLProtocol）。テストごとに別のホスト名で分ける（テストは並んで走る）。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data?
        var query: String? = nil
    }

    typealias Handler = @Sendable (Request) -> (status: Int, headers: [String: String], body: Data)
    static let handlers = Mutex<[String: Handler]>([:])

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    /// 新しいホストを用意して、そのホストへの要求に handler で答える。
    static func host(_ handler: @escaping Handler) -> URL {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        handlers.withLock { $0[host] = handler }
        return URL(string: "https://\(host)")!
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let handler = Self.handlers.withLock({ $0[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        let answer = handler(Request(method: request.httpMethod ?? "GET", path: url.path, headers: headers, body: body, query: url.query))
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> (status: Int, headers: [String: String], body: Data) {
    (status, ["content-type": "application/json"].merging(headers) { $1 }, try! JSONSerialization.data(withJSONObject: object))
}

private func recordingJSON(id: String, clientID: String, status: String, group: String? = nil, error: String? = nil) -> [String: Any] {
    var recording: [String: Any] = ["id": id, "client_id": clientID, "status": status, "summarize": false, "diarize": true]
    recording["group"] = group ?? NSNull()
    recording["error"] = error ?? NSNull()
    recording["duration_seconds"] = status == "done" ? 9.5 : NSNull()
    return ["recording": recording]
}

private func bodyObject(_ request: StubURLProtocol.Request) -> [String: Any] {
    (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

/// 架空の 16 kHz mono の WAV（1 秒の正弦波）
private func fictionalWAV() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-cloud-test-\(UUID().uuidString).wav")
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16],
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
    buffer.frameLength = 16_000
    for i in 0..<16_000 { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 16_000) }
    try file.write(from: buffer)
    return url
}

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
}

/// 決まった答えを順に返すサーバーの状態（録音 1 本分）
private final class FakeServer: Sendable {
    struct State {
        var created: [[String: Any]] = []
        var requests: [String] = []
        var statusPolls = 0
        var recordingStatus = "uploading"
        var failNextComplete: (Int, String)?
        var existingFailed = false
        var sttMissingOnce = false
    }

    let state = Mutex<State>(State())
    let stt: Data
    let id = "00000000-0000-4000-8000-000000000001"

    init(stt: Data) { self.stt = stt }

    func handle(_ request: StubURLProtocol.Request) -> (status: Int, headers: [String: String], body: Data) {
        state.withLock { s in
            s.requests.append("\(request.method) \(request.path)")
            let clientID = (s.created.last?["client_id"] as? String) ?? "unknown"
            switch (request.method, request.path) {
            case ("POST", "/v1/recordings"):
                s.created.append(bodyObject(request))
                if s.existingFailed {
                    s.existingFailed = false
                    return json(recordingJSON(id: id, clientID: clientID, status: "failed", error: "架空の失敗"))
                }
                return json(recordingJSON(id: id, clientID: clientID, status: s.recordingStatus, group: bodyObject(request)["group"] as? String), status: s.recordingStatus == "uploading" ? 201 : 200)
            case ("DELETE", "/v1/recordings/\(id)"):
                s.recordingStatus = "uploading"
                return (204, [:], Data())
            case ("PUT", "/v1/recordings/\(id)/audio"):
                return json(["bytes": 1000])
            case ("POST", "/v1/recordings/\(id)/complete"):
                if let (status, code) = s.failNextComplete {
                    s.failNextComplete = nil
                    return json(["error": code], status: status)
                }
                s.recordingStatus = "queued"
                return json(recordingJSON(id: id, clientID: clientID, status: "queued"), status: 202)
            case ("GET", "/v1/recordings/\(id)"):
                s.statusPolls += 1
                s.recordingStatus = s.statusPolls >= 2 ? "done" : "transcribing"
                return json(recordingJSON(id: id, clientID: clientID, status: s.recordingStatus))
            case ("GET", "/v1/recordings/\(id)/stt"):
                if s.sttMissingOnce {
                    s.sttMissingOnce = false
                    return json(["error": "not_found"], status: 404)
                }
                return (200, ["content-type": "application/json"], stt)
            default:
                return json(["error": "not_found"], status: 404)
            }
        }
    }
}

@Suite("Minutes クラウド（サーバーとのやり取り）")
struct MinutesCloudClientTests {
    @Test("録音の作り方: 値のない欄は送らず、Bearer の印を付け、Cookie は送らない")
    func createRecordingShape() async throws {
        let seen = Mutex<StubURLProtocol.Request?>(nil)
        let base = StubURLProtocol.host { request in
            seen.withLock { $0 = request }
            return json(recordingJSON(id: "r1", clientID: "mac-abc", status: "uploading"), status: 201)
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" })
        let recording = try await client.createRecording(MinutesCloudRecordingRequest(clientId: "mac-abc", source: "mac", timeZone: "Asia/Tokyo", language: "ja",
                                                                                         keyterms: ["架空の会社"], group: "mac-0123456789abcdef"))
        #expect(recording.id == "r1" && recording.status == "uploading")
        let request = try #require(seen.withLock { $0 })
        #expect(request.headers["authorization"] == "Bearer fictional-token")
        #expect(request.headers["cookie"] == nil)
        let body = bodyObject(request)
        #expect(body["client_id"] as? String == "mac-abc")
        #expect(body["summarize"] as? Bool == false && body["diarize"] as? Bool == true)
        #expect(body["content_type"] as? String == "audio/mp4" && body["time_zone"] as? String == "Asia/Tokyo")
        #expect(body["keyterms"] as? [String] == ["架空の会社"] && body["group"] as? String == "mac-0123456789abcdef")
        #expect(body["title"] == nil && body["started_at"] == nil && body["num_speakers"] == nil)
    }

    @Test("サーバーの誤りの名前を読み、ログインしていなければ送らない")
    func errors() async throws {
        let base = StubURLProtocol.host { _ in json(["error": "limit_exceeded", "seconds_needed": 600], status: 402) }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" })
        await #expect(throws: MinutesCloudError.http(status: 402, code: "limit_exceeded", requestID: nil)) {
            _ = try await client.account()
        }
        let signedOut = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { nil })
        await #expect(throws: MinutesCloudError.notSignedIn) { _ = try await signedOut.account() }
        #expect(MinutesCloudError.http(status: 402, code: "limit_exceeded", requestID: nil).localizedDescription.contains("使える量"))
    }

    @Test("メールのコードでログインし、印は応答の見出し set-auth-token から取る")
    func signIn() async throws {
        let seen = Mutex<[StubURLProtocol.Request]>([])
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append(request) }
            if request.path == "/v1/auth/sign-in/email-otp" {
                return json(["token": "raw", "user": ["id": "u1", "email": "kakuu@example.test"]], headers: ["set-auth-token": "signed-token"])
            }
            return json(["success": true])
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { nil })
        try await client.sendSignInCode(email: "kakuu@example.test")
        let session = try await client.signIn(email: "kakuu@example.test", code: "123456")
        #expect(session == MinutesCloudSession(token: "signed-token", userID: "u1", email: "kakuu@example.test"))
        let requests = seen.withLock { $0 }
        #expect(bodyObject(requests[0])["type"] as? String == "sign-in")
        #expect(bodyObject(requests[1])["otp"] as? String == "123456")
        #expect(requests.allSatisfy { $0.headers["authorization"] == nil && $0.headers["cookie"] == nil })
    }

    @Test("文字起こし: AAC で上げ、終わるまで待ち、直接 ElevenLabs に送ったときと同じ読み方で読む。2 回目は上げ直さない")
    func transcribe() async throws {
        let stt = try fixture("elevenlabs_scribe_v2")
        let server = FakeServer(stt: stt)
        let base = StubURLProtocol.host { server.handle($0) }
        let transcriber = MinutesCloudTranscriber(client: MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" }),
                                                  pollInterval: .milliseconds(10))
        let wav = try fictionalWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        let group = MinutesCloudGroup.key(meetingID: "01JFICTIONAL", run: "run-1")
        let request = TranscriptionRequest(audioURL: wav, language: "ja", diarize: true, keyterms: ["架空の会社", String(repeating: "長", count: 51)], groupKey: group)
        let result = try await transcriber.transcribe(request)
        let direct = ElevenLabsScribe.makeResult(from: try ElevenLabsScribe.parseResponse(stt))
        #expect(result.segments == direct.segments && result.words == direct.words)
        #expect(result.providerMeta[MinutesCloudTranscriber.groupMetaKey] == group)
        #expect(result.providerMeta["server_recording_id"] == server.id)
        let first = server.state.withLock { $0 }
        #expect(first.requests.filter { $0.hasPrefix("PUT ") }.count == 1)
        #expect(first.requests.filter { $0.hasSuffix("/complete") }.count == 1)
        #expect(first.created.first?["keyterms"] as? [String] == ["架空の会社"]) // 50 文字を超える語は送らない
        #expect(first.created.first?["group"] as? String == group)

        // 同じトラックをもう一度（後処理のやり直し）: 同じ client_id で、終わった録音の文字起こしを読むだけ
        server.state.withLock { $0.recordingStatus = "done" }
        _ = try await transcriber.transcribe(request)
        let second = server.state.withLock { $0 }
        #expect(second.created.count == 2 && second.created[0]["client_id"] as? String == second.created[1]["client_id"] as? String)
        #expect(second.requests.filter { $0.hasPrefix("PUT ") }.count == 1)
    }

    @Test("前の失敗は消して作り直す。使える量を超えたら（402）この Mac に切り替え、混雑（503）なら待つ")
    func failures() async throws {
        let server = FakeServer(stt: try fixture("elevenlabs_scribe_v2"))
        let base = StubURLProtocol.host { server.handle($0) }
        let transcriber = MinutesCloudTranscriber(client: MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" }),
                                                  pollInterval: .milliseconds(10))
        let wav = try fictionalWAV()
        defer { try? FileManager.default.removeItem(at: wav) }
        let request = TranscriptionRequest(audioURL: wav, language: "ja", diarize: false, groupKey: "mac-0123456789abcdef0123456789abcdef")

        server.state.withLock { $0.existingFailed = true }
        _ = try await transcriber.transcribe(request)
        #expect(server.state.withLock { $0.requests }.contains("DELETE /v1/recordings/\(server.id)"))

        server.state.withLock {
            $0.recordingStatus = "uploading"
            $0.statusPolls = 0
            $0.failNextComplete = (402, "limit_exceeded")
        }
        do {
            _ = try await transcriber.transcribe(request)
            Issue.record("402 で止まらなかった")
        } catch let error as TranscriptionError {
            guard case let .httpError(provider, status, _, _) = error else { Issue.record("違う誤り: \(error)"); return }
            #expect(provider == MinutesCloudTranscriber.providerID && status == 402)
            #expect(TransientFailure.reason(for: error) == nil)
        }
        #expect(TransientFailure.reason(for: MinutesCloudTranscriber.transcriptionError(.http(status: 503, code: "queue_unavailable", requestID: nil), provider: "minutes.cloud")) == .server)

        let signedOut = MinutesCloudTranscriber(client: MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { nil }))
        await #expect(throws: TranscriptionError.self) { _ = try await signedOut.transcribe(request) }

        // 終わった録音の文字起こしが消えていた（30 日を過ぎた）: 消して、もう一度上げる
        server.state.withLock {
            $0.recordingStatus = "done"
            $0.statusPolls = 0
            $0.sttMissingOnce = true
            $0.requests = []
        }
        _ = try await transcriber.transcribe(request)
        let requests = server.state.withLock { $0.requests }
        #expect(requests.contains("DELETE /v1/recordings/\(server.id)") && requests.contains("PUT /v1/recordings/\(server.id)/audio"))
    }

    @Test("要約: 組がなければ頼まない。組があれば Mac の SummaryInput をそのまま送り、終わった要約を受け取る")
    func summarize() async throws {
        let seen = Mutex<[StubURLProtocol.Request]>([])
        let polls = Mutex(0)
        let result: [String: Any] = [
            "summary_md": "- 架空の要約", "decisions": [["text": "架空の決定", "evidence": [0]]],
            "action_items": [["text": "架空の資料を送る", "owner": "me", "kind": "own_commitment", "due": NSNull(), "evidence": [1]]],
            "open_questions": [], "keyterms_learned": ["架空の用語"],
        ]
        let resultData = try JSONSerialization.data(withJSONObject: result)
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append(request) }
            if request.method == "POST" {
                return json(["summary": ["id": "s1", "client_id": bodyObject(request)["client_id"] ?? "", "group": "g", "status": "queued", "model": NSNull(), "error": NSNull(), "created_at": "2026-11-23T05:00:00.123Z", "completed_at": NSNull()]], status: 202)
            }
            let done = polls.withLock { $0 += 1; return $0 >= 2 }
            var summary: [String: Any] = ["id": "s1", "client_id": "c", "group": "g", "status": done ? "done" : "running", "model": done ? "claude-opus-5-5" : NSNull(), "error": NSNull(), "created_at": "2026-11-23T05:00:00.123Z", "completed_at": NSNull()]
            if done { summary["result"] = try! JSONSerialization.jsonObject(with: resultData) }
            return json(["summary": summary])
        }
        let summarizer = MinutesCloudSummarizer(client: MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" }), pollInterval: .milliseconds(10))
        let input = MinutesCloudContractTests.fictionalSummaryInput()
        await #expect(throws: MinutesCloudError.http(status: 403, code: "no_transcription", requestID: nil)) {
            _ = try await summarizer.summarize(input, context: SummaryContext(meetingID: "01JFICTIONAL"))
        }
        #expect(seen.withLock { $0 }.isEmpty)

        let summary = try await summarizer.summarize(input, context: SummaryContext(meetingID: "01JFICTIONAL", cloudGroup: "mac-0123456789abcdef0123456789abcdef"))
        #expect(summary.summaryMd == "- 架空の要約" && summary.actionItems.first?.kind == .ownCommitment && summary.keytermsLearned == ["架空の用語"])
        let post = try #require(seen.withLock { $0 }.first)
        let body = bodyObject(post)
        #expect(body["group"] as? String == "mac-0123456789abcdef0123456789abcdef" && body["time_zone"] as? String == TimeZone.current.identifier)
        #expect((body["client_id"] as? String)?.hasPrefix("mac-summary-") == true)
        let golden = try JSONSerialization.jsonObject(with: try fixture(MinutesCloudContractTests.goldenName)) as? NSDictionary
        #expect((body["input"] as? NSDictionary) == golden)
        // 題名を頼まない依頼には、欄ごと出さない
        #expect(body["suggest_title"] == nil)
    }

    @Test("要約: 題名も頼むと suggest_title を入力の外に付け、別の依頼（client_id）にして、返った題名を整えて受け取る")
    func summarizeWithTitle() async throws {
        let seen = Mutex<[StubURLProtocol.Request]>([])
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append(request) }
            let result: [String: Any] = ["summary_md": "- 架空の要約", "decisions": [], "action_items": [], "open_questions": [], "keyterms_learned": []]
            let asked = bodyObject(request)["suggest_title"] as? Bool == true
            var summary: [String: Any] = ["id": "s1", "client_id": bodyObject(request)["client_id"] ?? "", "group": "g", "status": "done", "model": "claude-opus-5-5", "error": NSNull(), "created_at": "2026-11-23T05:00:00.123Z", "completed_at": NSNull(), "result": result]
            // 古いサーバーは title を返さない。頼んでいない依頼に付いていても、題名にしない
            summary["title"] = asked ? "「架空の価格の相談」" : "頼んでいない題名"
            return json(["summary": summary], status: 202)
        }
        let summarizer = MinutesCloudSummarizer(client: MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" }), pollInterval: .milliseconds(10))
        let input = MinutesCloudContractTests.fictionalSummaryInput()
        let group = "mac-0123456789abcdef0123456789abcdef"
        let titled = try await summarizer.summarizeWithTitle(input, context: SummaryContext(meetingID: "01JFICTIONAL", cloudGroup: group, suggestTitle: true))
        #expect(titled.title == "架空の価格の相談" && titled.summary.summaryMd == "- 架空の要約")
        let plain = try await summarizer.summarizeWithTitle(input, context: SummaryContext(meetingID: "01JFICTIONAL", cloudGroup: group))
        #expect(plain.title == nil)
        let bodies = seen.withLock { $0 }.map(bodyObject)
        #expect(bodies.count == 2 && bodies[0]["suggest_title"] as? Bool == true && bodies[1]["suggest_title"] == nil)
        #expect(bodies[0]["client_id"] as? String != bodies[1]["client_id"] as? String)
        // 入力そのものは同じ（題名の依頼を入力に混ぜない）
        #expect(bodies[0]["input"] as? NSDictionary == bodies[1]["input"] as? NSDictionary)
    }

    @Test("組の名前は、同じ会議の同じ入力なら同じで、入力が変われば別になる（会議の ID は送らない）")
    func groupKey() {
        let a = MinutesCloudGroup.key(meetingID: "01JFICTIONAL", run: "audio-1")
        #expect(a == MinutesCloudGroup.key(meetingID: "01JFICTIONAL", run: "audio-1"))
        #expect(a != MinutesCloudGroup.key(meetingID: "01JFICTIONAL", run: "audio-2"))
        #expect(a != MinutesCloudGroup.key(meetingID: "01JOTHER", run: "audio-1"))
        #expect(a.hasPrefix("mac-") && a.count == 36 && !a.contains("01JFICTIONAL"))
    }

    @Test("アカウントの量を読む")
    func account() async throws {
        let base = StubURLProtocol.host { _ in json(["user": ["id": "u1"], "plan": "pro", "usage": ["seconds_this_month": 9.5, "seconds_pending": 0, "seconds_limit": 7200]]) }
        let account = try await MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" }).account()
        #expect(account.plan == "pro" && account.usage.secondsThisMonth == 9.5 && account.usage.secondsLimit == 7200)
    }

    @Test("閲覧用のリンク（P7）: 作る・一覧・取り消す。取り消しは、もうない（404）なら済んだとみなす")
    func shares() async throws {
        let seen = Mutex<[StubURLProtocol.Request]>([])
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append(request) }
            let share: [String: Any] = ["id": "s1", "url": "https://api.example.test/s/AAAA", "include_transcript": true,
                                        "created_at": "2026-11-24T08:00:15.360Z", "expires_at": "2026-12-01T08:00:15.360Z"]
            switch (request.method, request.path) {
            case ("POST", "/v1/recordings/r1/shares"): return json(["share": share], status: 201)
            case ("GET", "/v1/recordings/r1/shares"): return json(["shares": [share]])
            case ("DELETE", "/v1/recordings/r1/shares/s1"): return (204, [:], Data())
            case ("DELETE", "/v1/recordings/r1/shares/gone"): return json(["error": "not_found"], status: 404)
            case ("POST", "/v1/recordings/r2/shares"): return json(["error": "no_summary"], status: 409)
            default: return json(["error": "not_found"], status: 404)
            }
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" })
        let created = try await client.createShare(recordingID: "r1", includeTranscript: true, expiresInDays: 7)
        #expect(created.id == "s1" && created.url.absoluteString == "https://api.example.test/s/AAAA" && created.includeTranscript)
        #expect(created.expiresAt.timeIntervalSince(created.createdAt) == 7 * 86_400)
        let body = bodyObject(try #require(seen.withLock { $0.first }))
        #expect(body["include_transcript"] as? Bool == true && body["expires_in_days"] as? Int == 7)
        #expect(try await client.shares(recordingID: "r1") == [created])
        try await client.revokeShare(recordingID: "r1", shareID: "s1")
        try await client.revokeShare(recordingID: "r1", shareID: "gone")
        await #expect(throws: MinutesCloudError.http(status: 409, code: "no_summary", requestID: nil)) {
            _ = try await client.createShare(recordingID: "r2")
        }
        let defaults = bodyObject(try #require(seen.withLock { $0.last }))
        #expect(defaults["include_transcript"] as? Bool == false && defaults["expires_in_days"] as? Int == 30)
        #expect(MinutesCloudError.http(status: 409, code: "no_summary", requestID: nil).localizedDescription.contains("全文"))
    }

    @Test("通知の宛先: 小文字の 16 進で登録し、外す。外すとき、もうない・対応していないサーバー（404）なら済んだとみなす")
    func pushDevices() async throws {
        let seen = Mutex<[StubURLProtocol.Request]>([])
        let token = Data([0x00, 0x0f, 0xa0, 0xff] + [UInt8](repeating: 0xab, count: 28))
        let hex = "000fa0ff" + String(repeating: "ab", count: 28)
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append(request) }
            switch (request.method, request.path) {
            case ("PUT", "/v1/push-devices"): return json(["ok": true])
            case ("DELETE", "/v1/push-devices/\(hex)"): return seen.withLock { $0.count } > 2 ? json(["error": "not_found"], status: 404) : (204, [:], Data())
            default: return json(["error": "not_found"], status: 404)
            }
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" })
        try await client.registerPushDevice(token: token, environment: .sandbox)
        let put = try #require(seen.withLock { $0.first })
        #expect(put.headers["authorization"] == "Bearer fictional-token")
        let body = bodyObject(put)
        #expect(body["token"] as? String == hex && body["environment"] as? String == "sandbox" && hex.count == 64)
        try await client.unregisterPushDevice(token: token)
        try await client.unregisterPushDevice(token: token)
        #expect(seen.withLock { $0.count } == 3)
        let signedOut = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { nil })
        await #expect(throws: MinutesCloudError.notSignedIn) { try await signedOut.registerPushDevice(token: token, environment: .production) }
    }
}
