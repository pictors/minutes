import AVFoundation
import Foundation
@testable import MinutesCore
import Synchronization
import Testing

// 製品版の P4（iPhone・Watch）: サーバーとのやり取りの追加と、区切りで上げる記録。架空の値だけを使う。

private func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> (status: Int, headers: [String: String], body: Data) {
    (status, ["content-type": "application/json"].merging(headers) { $1 }, try! JSONSerialization.data(withJSONObject: object))
}

private func bodyObject(_ request: StubURLProtocol.Request) -> [String: Any] {
    (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

/// サーバーの transcript.json の形（日時は JavaScript の toISOString なのでミリ秒が付く）
private let serverTranscript = """
{"schema_version":1,"meeting":{"id":"00000000-0000-4000-8000-0000000000aa","title":"架空の定例","started_at":"2026-11-23T01:02:03.456Z","duration_seconds":74.2},
 "provider":"elevenlabs","language":"ja",
 "speakers":[{"label":"spk_0","name":null,"provider_label":"speaker_0","track":"system"}],
 "segments":[{"id":0,"track":"system","t_start":0.1,"t_end":2.5,"speaker":"spk_0","text":"架空の発言です。","confidence":null}],
 "provider_meta":{"model":"scribe_v2"},"created_at":"2026-11-23T01:05:00.123Z"}
"""

private let serverSummary = """
{"summary_md":"**結論：架空の案件を進める。**","decisions":[{"text":"架空の決定","evidence":[0]}],
 "action_items":[{"text":"架空の資料を送る","owner":"spk_0","kind":"their_task","due":null,"evidence":[0]}],
 "open_questions":[{"text":"架空の論点","evidence":[0]}],"keyterms_learned":["架空の用語"]}
"""

@Suite("キーなし（iPhone・Watch のやり取り）")
struct MinutesCloudDeviceClientTests {
    @Test("日時はミリ秒のあり・なしの両方を読む（サーバーの toISOString と、今までの .iso8601）")
    func tolerantDates() throws {
        #expect(JSONCoding.parseISO8601("2026-11-23T01:02:03.456Z") != nil)
        #expect(JSONCoding.parseISO8601("2026-11-23T01:02:03Z") != nil)
        #expect(JSONCoding.parseISO8601("2026-11-23T10:02:03+09:00") == JSONCoding.parseISO8601("2026-11-23T01:02:03Z"))
        #expect(JSONCoding.parseISO8601("2026-11-23") == nil)
        let document = try JSONCoding.decoder().decode(TranscriptDocument.self, from: Data(serverTranscript.utf8))
        #expect(document.segments.first?.text == "架空の発言です。")
        #expect(document.meeting.startedAt == JSONCoding.parseISO8601("2026-11-23T01:02:03.456Z"))
        // Mac が書いたもの（小数なし）は今までどおり読める
        let written = try JSONCoding.encoder().encode(document)
        #expect(try JSONCoding.decoder().decode(TranscriptDocument.self, from: written).segments == document.segments)
    }

    @Test("Sign in with Apple: idToken は camelCase のまま、生の nonce を送り、印は set-auth-token から取る")
    func appleSignIn() async throws {
        let seen = Mutex<StubURLProtocol.Request?>(nil)
        let base = StubURLProtocol.host { request in
            seen.withLock { $0 = request }
            return json(["redirect": false, "token": "raw", "user": ["id": "u1", "email": "kakuu@privaterelay.appleid.com"]], headers: ["set-auth-token": "signed"])
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { nil })
        let nonce = MinutesCloudAppleNonce(raw: "kakuu-nonce")
        #expect(nonce.hashed == MinutesCloudUpload.digest(Data("kakuu-nonce".utf8)))
        let session = try await client.signInWithApple(identityToken: "kakuu.identity.token", rawNonce: nonce.raw)
        #expect(session.token == "signed" && session.userID == "u1")
        let request = try #require(seen.withLock { $0 })
        #expect(request.path == "/v1/auth/sign-in/social" && request.headers["authorization"] == nil)
        let body = bodyObject(request)
        #expect(body["provider"] as? String == "apple")
        let idToken = try #require(body["idToken"] as? [String: String])
        #expect(idToken == ["token": "kakuu.identity.token", "nonce": "kakuu-nonce"])
        #expect(MinutesCloudAppleNonce.make() != MinutesCloudAppleNonce.make())
        #expect(MinutesCloudAppleNonce.make().raw.count == 64)
    }

    @Test("ログイン中の利用者を読み、Apple の中継のアドレスを見分ける")
    func currentUser() async throws {
        let base = StubURLProtocol.host { _ in
            json(["session": ["id": "s1"], "user": ["id": "u1", "email": "kakuu@privaterelay.appleid.com", "name": ""]])
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "t" })
        let user = try await client.currentUser()
        #expect(user.id == "u1" && user.isApplePrivateRelay)
        #expect(!MinutesCloudUser(id: "u2", email: "kakuu@example.test").isApplePrivateRelay)
        let signedOut = StubURLProtocol.host { _ in (200, ["content-type": "application/json"], Data("null".utf8)) }
        await #expect(throws: MinutesCloudError.self) {
            _ = try await MinutesCloudClient(baseURL: signedOut, session: StubURLProtocol.session(), token: { "t" }).currentUser()
        }
    }

    @Test("録音の一覧・文字起こし・議事録を読む（日時のミリ秒を含む）")
    func readRecordings() async throws {
        let id = "00000000-0000-4000-8000-0000000000aa"
        let base = StubURLProtocol.host { request in
            switch request.path {
            case "/v1/recordings":
                return json(["recordings": [[
                    "id": id, "client_id": "watch-01kakuu", "source": "watch", "title": "架空の定例", "started_at": "2026-11-23T01:02:03.456Z",
                    "time_zone": "Asia/Tokyo", "language": NSNull(), "status": "done", "error": NSNull(), "duration_seconds": 74.2, "detected_language": "ja",
                    "speaker_count": 3, "audio_bytes": 215_000, "audio_expires_at": "2026-12-23T01:05:00.000Z", "audio_deleted": false,
                    "summary_model": "claude-opus-5-5", "summary_error": NSNull(), "summarize": true, "diarize": true, "group": NSNull(),
                    "created_at": "2026-11-23T01:02:04.000Z", "completed_at": "2026-11-23T01:05:00.123Z",
                ]]])
            case "/v1/recordings/\(id)/transcript": return (200, ["content-type": "application/json"], Data(serverTranscript.utf8))
            case "/v1/recordings/\(id)/summary": return (200, ["content-type": "application/json"], Data(serverSummary.utf8))
            default: return json(["error": "not_ready"], status: 404)
            }
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "t" })
        let recording = try #require(try await client.recordings().first)
        #expect(recording.source == "watch" && recording.status == "done" && recording.speakerCount == 3)
        #expect(recording.startedAt == JSONCoding.parseISO8601("2026-11-23T01:02:03.456Z") && recording.audioDeleted == false)
        #expect(try await client.transcript(recordingID: id).segments.count == 1)
        let summary = try await client.summary(recordingID: id)
        #expect(summary.decisions.first?.text == "架空の決定" && summary.actionItems.first?.kind == .theirTask)
        await #expect(throws: MinutesCloudError.http(status: 404, code: "not_ready", requestID: nil)) {
            _ = try await client.summary(recordingID: "00000000-0000-4000-8000-0000000000bb")
        }
    }

    @Test("区切りの送り先と complete の本文（走ごとのバイト数）")
    func partsAndComplete() async throws {
        let seen = Mutex<[StubURLProtocol.Request]>([])
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append(request) }
            if request.path.hasSuffix("/complete") { return json(["recording": ["id": "r1", "client_id": "iphone-01kakuu", "status": "queued"]], status: 202) }
            return json(["bytes": request.body?.count ?? 0])
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "t" })
        let file = FileManager.default.temporaryDirectory.appending(path: "minutes-part-\(UUID().uuidString).aac")
        try Data([0xFF, 0xF1, 0x50, 0x80]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await client.uploadPart(recordingID: "r1", run: 2, offset: 120_000, fileURL: file, contentType: "audio/aac")
        let recording = try await client.complete(recordingID: "r1", durationSeconds: 61.5,
                                                  runs: [MinutesCloudRunBytes(run: 0, bytes: 240_000), MinutesCloudRunBytes(run: 1, bytes: 0)])
        #expect(recording.status == "queued")
        let requests = seen.withLock { $0 }
        #expect(requests.first?.method == "PUT" && requests.first?.path == "/v1/recordings/r1/parts/2/120000")
        #expect(requests.first?.headers["content-type"] == "audio/aac" && requests.first?.body?.count == 4)
        let body = bodyObject(try #require(requests.last))
        #expect(body["duration_seconds"] as? Double == 61.5)
        #expect((body["runs"] as? [[String: Int]]) == [["run": 0, "bytes": 240_000], ["run": 1, "bytes": 0]])
        // 長さも走も分からなければ空の本文
        #expect(String(decoding: try MinutesCloudClient.completeBody(durationSeconds: nil, runs: nil), as: UTF8.self) == "{}")
        let request = try client.partUploadRequest(recordingID: "r1", run: 0, offset: 0, contentType: "audio/aac")
        #expect(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "authorization") == "Bearer t")
    }

    @Test("アカウントの削除: Apple のコードを添え、取り消しの結果を読む")
    func deleteAccount() async throws {
        let seen = Mutex<StubURLProtocol.Request?>(nil)
        let base = StubURLProtocol.host { request in
            seen.withLock { $0 = request }
            return json(["deleted": true, "apple_revoked": false, "apple_reason": "no_code"])
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "t" })
        let result = try await client.deleteAccount(appleAuthorizationCode: "kakuu-code")
        #expect(result.deleted && !result.appleRevoked && result.appleReason == "no_code")
        let request = try #require(seen.withLock { $0 })
        #expect(request.method == "DELETE" && request.path == "/v1/account")
        #expect(bodyObject(request)["apple_authorization_code"] as? String == "kakuu-code")
    }

    @Test("音声を取りに行き、期限を過ぎていれば誤りの名前を返す")
    func downloadAudio() async throws {
        let base = StubURLProtocol.host { request in
            request.path.hasSuffix("/r1/audio") ? (200, ["content-type": "audio/aac"], Data([0xFF, 0xF1, 1, 2, 3])) : json(["error": "audio_not_available"], status: 404)
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "t" })
        let destination = FileManager.default.temporaryDirectory.appending(path: "minutes-audio-\(UUID().uuidString).aac")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await client.downloadAudio(recordingID: "r1", to: destination)
        #expect(try Data(contentsOf: destination) == Data([0xFF, 0xF1, 1, 2, 3]))
        await #expect(throws: MinutesCloudError.http(status: 404, code: "audio_not_available", requestID: nil)) {
            try await client.downloadAudio(recordingID: "r2", to: destination)
        }
    }
}

@Suite("区切りで上げる記録（MinutesCloudUpload）")
struct MinutesCloudUploadTests {
    private func upload() -> MinutesCloudUpload {
        MinutesCloudUpload(clientId: "iphone-01kakuu", source: "iphone", title: "架空の定例", startedAt: Date(timeIntervalSince1970: 1_800_000_000), timeZone: "Asia/Tokyo")
    }

    @Test("録音中は決まった大きさで区切り、半端は次に回す。閉じた走は残りをすべて区切る")
    func planning() {
        var u = upload()
        let run = u.startRun(at: u.startedAt)
        #expect(run.index == 0 && run.fileName == "run-0.aac")
        #expect(u.planParts(fileSizes: [0: 50], minimumBytes: 100, maximumBytes: 250).isEmpty)
        #expect(u.planParts(fileSizes: [0: 130], minimumBytes: 100, maximumBytes: 250) == [.init(run: 0, offset: 0, size: 130)])
        // 130 → 700: 250 + 250 を区切り、残りの 70 は次に回す
        #expect(u.planParts(fileSizes: [0: 700], minimumBytes: 100, maximumBytes: 250).map(\.offset) == [130, 380])
        #expect(u.plannedBytes(run: 0) == 630)
        // 同じ大きさなら何も足さない（上げ直しでも境目は変わらない）
        #expect(u.planParts(fileSizes: [0: 700], minimumBytes: 100, maximumBytes: 250).isEmpty)
        u.finishRun(0, durationSeconds: 5)
        #expect(u.planParts(fileSizes: [0: 700], minimumBytes: 100, maximumBytes: 250) == [.init(run: 0, offset: 630, size: 70)])
        // 中断のあとの走
        let second = u.startRun(at: u.startedAt.addingTimeInterval(9))
        #expect(second.index == 1 && second.fileName == "run-1.aac")
        u.finishRun(1, durationSeconds: 2)
        #expect(u.planParts(fileSizes: [0: 700, 1: 40], minimumBytes: 100, maximumBytes: 250) == [.init(run: 1, offset: 0, size: 40)])
        #expect(u.runBytes == [MinutesCloudRunBytes(run: 0, bytes: 700), MinutesCloudRunBytes(run: 1, bytes: 40)])
        #expect(u.gaps == [DateInterval(start: u.startedAt.addingTimeInterval(5), end: u.startedAt.addingTimeInterval(9))])
        #expect(u.durationSeconds == 7)
    }

    @Test("complete は、止めて・区切りがすべて上がって・サーバーの ID があるときだけ")
    func readiness() {
        var u = upload()
        u.startRun(at: u.startedAt)
        u.planParts(fileSizes: [0: 300], minimumBytes: 100, maximumBytes: 1000)
        u.markUploaded(run: 0, offset: 0)
        #expect(!u.readyToComplete(fileSizes: [0: 300]))  // 止めていない
        u.stop()
        #expect(u.runs.allSatisfy { $0.finished })
        #expect(!u.readyToComplete(fileSizes: [0: 300]))  // サーバーの ID がない
        u.serverId = "r1"
        #expect(u.readyToComplete(fileSizes: [0: 300]))
        #expect(!u.readyToComplete(fileSizes: [0: 360]))  // ファイルの終わりまで区切っていない
        u.planParts(fileSizes: [0: 360])
        #expect(!u.readyToComplete(fileSizes: [0: 360]))  // 残りがまだ上がっていない
        u.markUploaded(run: 0, offset: 300)
        #expect(u.readyToComplete(fileSizes: [0: 360]))
        u.completed = true
        #expect(!u.readyToComplete(fileSizes: [0: 360]))
        // 何も録れていない録音は送らない
        var empty = upload()
        empty.startRun(at: empty.startedAt)
        empty.stop()
        empty.serverId = "r2"
        #expect(empty.isEmpty(fileSizes: [0: 0]) && !empty.readyToComplete(fileSizes: [0: 0]))
    }

    @Test("閉じたファイルが切り出したときと違えば、その区切りを上げ直す")
    func invalidation() throws {
        var u = upload()
        u.startRun(at: u.startedAt)
        u.planParts(fileSizes: [0: 200], minimumBytes: 100, maximumBytes: 100)
        u.recordDigest(run: 0, offset: 0, sha256: "aaa")
        u.recordDigest(run: 0, offset: 100, sha256: "bbb")
        u.markUploaded(run: 0, offset: 0)
        u.markUploaded(run: 0, offset: 100)
        let changed = u.invalidateChangedParts(run: 0) { $0.offset == 0 ? "aaa" : "changed" }
        #expect(changed.map(\.offset) == [100])
        #expect(u.pendingParts.map(\.offset) == [100] && u.parts[1].sha256 == nil)
        u.resendRun(0)
        #expect(u.pendingParts.count == 2)
    }

    @Test("upload.json に書いて読み戻す・ADTS の見分け・区切りの読み出し")
    func files() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "minutes-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var u = upload()
        u.startRun(at: u.startedAt)
        u.planParts(fileSizes: [0: 8], minimumBytes: 4, maximumBytes: 5)
        try u.save(to: directory)
        #expect(try MinutesCloudUpload.load(from: directory) == u)
        #expect(MinutesCloudUpload.isADTS(Data([0xFF, 0xF1, 0x50])) && MinutesCloudUpload.isADTS(Data([0xFF, 0xF9])))
        #expect(!MinutesCloudUpload.isADTS(Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70])) && !MinutesCloudUpload.isADTS(Data([0xFF])))
        let runFile = directory.appending(path: "run-0.aac")
        try Data([0, 1, 2, 3, 4, 5, 6, 7]).write(to: runFile)
        #expect(try MinutesCloudUpload.readPart(u.parts[0], from: runFile) == Data([0, 1, 2, 3, 4]))
        #expect(try MinutesCloudUpload.readPart(.init(run: 0, offset: 5, size: 3), from: runFile) == Data([5, 6, 7]))
        #expect(throws: MinutesCloudError.self) { _ = try MinutesCloudUpload.readPart(.init(run: 0, offset: 6, size: 3), from: runFile) }
        #expect(u.recordingRequest.summarize && u.recordingRequest.contentType == "audio/aac" && u.recordingRequest.clientId == "iphone-01kakuu")
        #expect(MinutesCloudUpload.newClientID(source: "watch").hasPrefix("watch-"))
    }

    @Test("書いている途中の ADTS を区切って上げても、閉じたファイルと同じバイト列になる（AVAudioFile、16 kHz mono 32 kbps）")
    func growingADTS() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "minutes-adts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var u = upload()
        let run = u.startRun(at: u.startedAt)
        let url = directory.appending(path: run.fileName)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try #require(file?.processingFormat)
        var uploaded = Data()
        for second in 0..<20 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
            buffer.frameLength = 8_000
            for i in 0..<8_000 { buffer.floatChannelData![0][i] = 0.2 * sin(Float(second * 8_000 + i) * 2 * .pi * 330 / 16_000) }
            try file?.write(from: buffer)
            let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            for part in u.planParts(fileSizes: [0: size], minimumBytes: 1_000, maximumBytes: 3_000) {
                let data = try MinutesCloudUpload.readPart(part, from: url)
                u.recordDigest(run: 0, offset: part.offset, sha256: MinutesCloudUpload.digest(data))
                u.markUploaded(run: 0, offset: part.offset)
                uploaded.append(data)
            }
        }
        file = nil  // 閉じる
        let final = try Data(contentsOf: url)
        #expect(MinutesCloudUpload.isADTS(final))
        u.finishRun(0, durationSeconds: 10)
        let changed = try u.invalidateChangedParts(run: 0) { MinutesCloudUpload.digest(try MinutesCloudUpload.readPart($0, from: url)) }
        #expect(changed.isEmpty)
        for part in u.planParts(fileSizes: [0: final.count]) {
            uploaded.append(try MinutesCloudUpload.readPart(part, from: url))
            u.markUploaded(run: 0, offset: part.offset)
        }
        #expect(uploaded == final)
        #expect(u.parts.count > 3)
    }
}
