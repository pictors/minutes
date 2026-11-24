import CryptoKit
import Foundation

// Minutes のサーバー（Minutes クラウド: 自分の API キーなしで文字起こしと要約を使う有料の手段）とのやり取り。
// Mac・iPhone・Watch で共通（SPEC §5.6）。ログインの印（Bearer）は呼び出し側が持ち、ここでは保存しない。Cookie は使わない。
// API の形（2026-11-23 確認）: サーバーの docs/mac-keyless.md（非公開）と同じもの。
//   ログイン: POST /v1/auth/email-otp/send-verification-otp {email, type: "sign-in"} → POST /v1/auth/sign-in/email-otp {email, otp}
//            （応答の見出し set-auth-token が印）、POST /v1/auth/sign-in/email {email, password}、POST /v1/auth/sign-out
//   アカウント: GET /v1/me → {user:{id}, plan, usage:{seconds_this_month, seconds_pending, seconds_limit}}
//   文字起こし: POST /v1/recordings（summarize=false・diarize・keyterms・group）→ PUT /v1/recordings/:id/audio → POST /complete
//             → GET /v1/recordings/:id（status: uploading・queued・transcribing・summarizing・done・failed）→ GET /stt（ElevenLabs の応答の形）
//   要約: POST /v1/summaries {client_id, group, time_zone, input: SummaryInput} → GET /v1/summaries/:id（status・result）
//   誤り: {"error": "<code>"}（ログインの入口は {"code": "<CODE>", "message": …}）。401 は印がない・切れた
// iPhone・Watch（製品版の P4、2026-11-23 確認。サーバーの README の表）:
//   ログイン: POST /v1/auth/sign-in/social {provider: "apple", idToken: {token, nonce}}（生の nonce を送り、Apple には SHA-256 の 16 進を渡す）
//            GET /v1/auth/get-session → {session, user:{id, email}}
//   録音: POST /v1/recordings（summarize は既定の true）→ PUT /v1/recordings/:id/parts/:run/:offset（区切り）→ POST /complete {duration_seconds, runs:[{run, bytes}]}
//         GET /v1/recordings → {recordings:[…]}（新しい順に 100 件）、GET /:id/transcript（transcript.json）・/:id/summary（summary.json）・/:id/audio
//   アカウントの削除: DELETE /v1/account {apple_authorization_code?} → {deleted, apple_revoked, apple_reason}

/// サーバーの場所と、Cookie を使わない URLSession。
public extension URLSession {
    /// Minutes クラウドのサーバー用。Cookie も応答の写しも持たない（印は Authorization: Bearer で送る）。
    /// 回線がないときはすぐに失敗させる（待つのは後処理のキュー。SPEC §8.2）。
    static let minutesCloud: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

public enum MinutesCloudError: Error, LocalizedError, Equatable, Sendable {
    /// ログインしていない（印がない）。
    case notSignedIn
    /// サーバーが断った。code はサーバーの誤りの名前（limit_exceeded など）。
    case http(status: Int, code: String?, requestID: String?)
    case invalidResponse(String)
    /// 待っても終わらなかった。
    case timedOut(String)
    /// サーバーでの処理が失敗した（文字起こし・要約）。
    case failed(String)

    public var status: Int? {
        if case let .http(status, _, _) = self { return status }
        if case .notSignedIn = self { return 401 }
        return nil
    }

    public var code: String? {
        if case let .http(_, code, _) = self { return code }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Minutes アカウントにログインしていません"
        case let .http(status, code, requestID):
            let id = requestID.map { " request-id=\($0)" } ?? ""
            return (Self.message(status: status, code: code) ?? "Minutes のサーバーが HTTP \(status)\(code.map { "（\($0)）" } ?? "") を返しました") + id
        case let .invalidResponse(detail):
            return "Minutes のサーバーの応答を読めません: \(detail)"
        case let .timedOut(detail):
            return "Minutes のサーバーの処理が時間内に終わりませんでした: \(detail)"
        case let .failed(detail):
            return "Minutes のサーバーでの処理が失敗しました: \(detail)"
        }
    }

    static func message(status: Int, code: String?) -> String? {
        switch code {
        case "unauthorized": return "Minutes のログインが切れました。ログインし直してください"
        case "limit_exceeded": return "今月の使える量を超えました"
        case "no_plan": return "文字起こしと要約は、有料のプランで使えます"
        case "no_transcription": return "Minutes クラウドの要約は、Minutes クラウドで文字起こしした会議（30 日以内）だけで使えます"
        case "too_many_summaries": return "この会議の要約は、もう作り直せません（10 回まで）"
        case "group_full": return "この会議はもう送れません（同じ会議の録音は 2 本まで）"
        case "parts_missing": return "録音の一部がまだサーバーに届いていません"
        case "no_audio": return "サーバーに録音が届いていません"
        case "too_large": return "録音が大きすぎて送れません"
        case "not_ready": return "議事録はまだできていません"
        case "audio_not_available": return "音声は保存の期間（30 日）を過ぎて消えました"
        case "unknown_speaker": return "文字起こしにない話者です"
        case "bad_speaker_names": return "話者の名前は 50 文字までにしてください"
        case "no_summary": return "この会議には要約がありません。全文も入れて共有してください"
        case "not_shareable": return "この会議はリンクで共有できません"
        case "too_many_shares": return "この会議のリンクが多すぎます（20 まで）。使わないリンクを取り消してください"
        case "not_found": return "サーバーに見つかりません（消えたか、別のアカウントのものです）"
        case "TOO_MANY_CODES": return "コードを送りすぎました。しばらくしてからもう一度試してください"
        case "INVALID_OTP": return "コードが違います"
        case "OTP_EXPIRED": return "コードの期限が切れました。もう一度送ってください"
        case "TOO_MANY_ATTEMPTS": return "コードを 3 回まちがえました。コードを送り直してください"
        case "INVALID_EMAIL_OR_PASSWORD": return "メールアドレスかパスワードが違います"
        case "INVALID_EMAIL": return "メールアドレスの形が違います"
        default: return status == 429 ? "混み合っています。しばらくしてからもう一度試してください" : nil
        }
    }
}

/// ログインの結果。token は以後の要求の Authorization: Bearer に使う（Keychain に置くのは呼び出し側）。
public struct MinutesCloudSession: Sendable, Equatable {
    public var token: String
    public var userID: String?
    public var email: String?

    public init(token: String, userID: String?, email: String?) {
        self.token = token
        self.userID = userID
        self.email = email
    }
}

public struct MinutesCloudAccount: Decodable, Sendable, Equatable {
    public struct User: Decodable, Sendable, Equatable {
        public var id: String
    }

    public struct Usage: Decodable, Sendable, Equatable {
        public var secondsThisMonth: Double
        public var secondsPending: Double
        public var secondsLimit: Double
    }

    public var user: User
    /// "free" | "pro"
    public var plan: String
    public var usage: Usage
}

/// サーバーの録音（GET /v1/recordings・/:id）。Mac の Minutes クラウドが使う欄のほかは、iPhone・Watch の一覧と議事録の表示に使う。
public struct MinutesCloudRecording: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var clientId: String
    /// "watch" | "iphone" | "mac" | "import" | "test"
    public var source: String?
    public var title: String?
    public var startedAt: Date?
    public var timeZone: String?
    /// 指定した会議の言語（"ja" | "en"。nil は自動）
    public var language: String?
    /// uploading・queued・transcribing・summarizing・done・failed
    public var status: String
    public var error: String?
    public var durationSeconds: Double?
    /// 文字起こしで分かった言語
    public var detectedLanguage: String?
    public var speakerCount: Int?
    public var audioBytes: Int?
    /// 音声を消す予定の日時（保存は 30 日）
    public var audioExpiresAt: Date?
    public var audioDeleted: Bool?
    public var summaryModel: String?
    /// 要約だけが失敗したとき（文字起こしはできている）
    public var summaryError: String?
    public var summarize: Bool?
    public var diarize: Bool?
    public var group: String?
    public var createdAt: Date?
    public var completedAt: Date?

    public var isFinished: Bool { status == "done" || status == "failed" }
}

/// complete に添える、走（中断で分かれた録音）ごとのバイト数（サーバーは届いた区切りと合わせる）。
public struct MinutesCloudRunBytes: Codable, Sendable, Equatable {
    public var run: Int
    public var bytes: Int

    public init(run: Int, bytes: Int) {
        self.run = run
        self.bytes = bytes
    }
}

/// ログイン中の利用者（GET /v1/auth/get-session）。メールアドレスは、Apple の「メールを非公開」なら中継のアドレス。
public struct MinutesCloudUser: Codable, Sendable, Equatable {
    public var id: String
    public var email: String?

    public init(id: String, email: String?) {
        self.id = id
        self.email = email
    }

    /// Apple の「メールを非公開」で作ったアカウント（Mac では、このアドレスでコードを受け取る。Apple が本当のアドレスへ転送する）。
    public var isApplePrivateRelay: Bool { email?.lowercased().hasSuffix("@privaterelay.appleid.com") == true }
}

/// アカウントの削除の結果（DELETE /v1/account）。Apple のログインの取り消しに失敗しても、アカウントは消える。
public struct MinutesCloudAccountDeletion: Decodable, Sendable, Equatable {
    public var deleted: Bool
    public var appleRevoked: Bool
    /// no_code・no_apple_account・Apple の誤りの名前など
    public var appleReason: String?
}

/// 文字起こしだけの録音の作り方（POST /v1/recordings）。値のない欄は送らない（サーバーの既定）。
public struct MinutesCloudRecordingRequest: Encodable, Sendable, Equatable {
    public var clientId: String
    /// "mac" | "import" | "iphone" | "watch" | "test"
    public var source: String
    public var title: String?
    /// ISO 8601
    public var startedAt: String?
    public var timeZone: String
    /// "ja" | "en"。nil は自動
    public var language: String?
    /// "audio/mp4" | "audio/aac"
    public var contentType: String
    public var summarize: Bool
    public var diarize: Bool
    public var numSpeakers: Int?
    public var keyterms: [String]?
    public var group: String?

    public init(clientId: String, source: String, title: String? = nil, startedAt: String? = nil, timeZone: String = TimeZone.current.identifier, language: String? = nil,
                contentType: String = "audio/mp4", summarize: Bool = false, diarize: Bool = true, numSpeakers: Int? = nil, keyterms: [String]? = nil, group: String? = nil) {
        self.clientId = clientId
        self.source = source
        self.title = title
        self.startedAt = startedAt
        self.timeZone = timeZone
        self.language = language
        self.contentType = contentType
        self.summarize = summarize
        self.diarize = diarize
        self.numSpeakers = numSpeakers
        self.keyterms = keyterms
        self.group = group
    }
}

/// 閲覧用のリンク（P7、/v1/recordings/:id/shares）。URL を知る人は、ログインなしで議事録を読める。音声は共有しない。
public struct MinutesCloudShare: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var url: URL
    /// 全文も見せるか（既定は要約だけ）
    public var includeTranscript: Bool
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: String, url: URL, includeTranscript: Bool, createdAt: Date, expiresAt: Date) {
        self.id = id
        self.url = url
        self.includeTranscript = includeTranscript
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// リンクの期限として選べる日数（既定は 30 日）
    public static let expiryChoices = [7, 30, 90]
    public static let defaultExpiryDays = 30
}

public struct MinutesCloudSummaryJob: Decodable, Sendable, Equatable {
    public var id: String
    public var clientId: String
    public var group: String
    /// queued・running・done・failed
    public var status: String
    public var model: String?
    public var error: String?
    public var result: MinutesSummary?

    public var isFinished: Bool { status == "done" || status == "failed" }
}

/// 同じ会議の 1 回の文字起こし（相手側と自分のマイク）と、その要約を、サーバーの上で組にする名前（サーバーの使える量は組の中の長いほうだけ数える）。
/// run は文字起こしの入力（音声・手がかりの語・言語など）。同じ入力のやり直しは同じ組（上げ直さない）、入力が変わった文字起こしし直しは別の組になる。
/// 会議の ID そのものは送らず、ハッシュにする。
public enum MinutesCloudGroup {
    public static func key(meetingID: String, run: String) -> String {
        "mac-" + SHA256.hash(data: Data("minutes-meeting:\(meetingID)\n\(run)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Minutes のサーバーとのやり取り。
public struct MinutesCloudClient: Sendable {
    public static let productionBaseURL = URL(string: "https://api.minutes.tools")!

    public var baseURL: URL
    public var session: URLSession
    /// ログインの印（なければ nil）。呼ぶたびに読む（ログアウト・ログインし直しをすぐ反映する）。
    public var token: @Sendable () -> String?

    public init(baseURL: URL = MinutesCloudClient.productionBaseURL, session: URLSession = .minutesCloud, token: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
    }

    // MARK: ログイン

    /// ログイン（なければ登録）のコードをメールに送る。
    public func sendSignInCode(email: String) async throws {
        _ = try await send("POST", "/v1/auth/email-otp/send-verification-otp", json: ["email": email, "type": "sign-in"], authorized: false)
    }

    /// メールのコードでログインする（アカウントがなければ、ここで作る）。
    public func signIn(email: String, code: String) async throws -> MinutesCloudSession {
        try await signIn(path: "/v1/auth/sign-in/email-otp", body: ["email": email, "otp": code])
    }

    /// パスワードでログインする（パスワードを決めた人だけ）。
    public func signIn(email: String, password: String) async throws -> MinutesCloudSession {
        try await signIn(path: "/v1/auth/sign-in/email", body: ["email": email, "password": password])
    }

    /// Sign in with Apple（iPhone・Watch）。identityToken は Apple の identity token、rawNonce は Apple に SHA-256 を渡した生の nonce
    /// （MinutesCloudAppleNonce）。アカウントがなければ、ここで作る。
    public func signInWithApple(identityToken: String, rawNonce: String) async throws -> MinutesCloudSession {
        // Better Auth の名前（idToken）は camelCase のまま送る（JSONCoding の snake_case にしない）
        let body = try JSONSerialization.data(withJSONObject: ["provider": "apple", "idToken": ["token": identityToken, "nonce": rawNonce]])
        return try await signIn(path: "/v1/auth/sign-in/social", body: body)
    }

    /// ログイン中の利用者（ID とメールアドレス）。
    public func currentUser() async throws -> MinutesCloudUser {
        struct Body: Decodable {
            var user: MinutesCloudUser?
        }
        guard let user = try decode(Body.self, from: try await send("GET", "/v1/auth/get-session").0).user else {
            throw MinutesCloudError.http(status: 401, code: "unauthorized", requestID: nil)
        }
        return user
    }

    /// この端末のログインを取り消す（印はサーバーで使えなくなる）。
    public func signOut() async throws {
        _ = try await send("POST", "/v1/auth/sign-out", json: [String: String]())
    }

    /// アカウントを消す（録音・文字起こし・要約もサーバーから消える）。Apple でログインしたアカウントは、削除の直前に
    /// Sign in with Apple で取った authorization code を渡すと、Apple のログインも取り消す（なくても消す）。
    public func deleteAccount(appleAuthorizationCode: String? = nil, appleClientID: String? = nil) async throws -> MinutesCloudAccountDeletion {
        var body: [String: String] = [:]
        if let appleAuthorizationCode { body["apple_authorization_code"] = appleAuthorizationCode }
        if let appleClientID { body["apple_client_id"] = appleClientID }
        return try decode(MinutesCloudAccountDeletion.self, from: try await send("DELETE", "/v1/account", json: body).0)
    }

    private func signIn(path: String, body: [String: String]) async throws -> MinutesCloudSession {
        try await signIn(path: path, body: try JSONSerialization.data(withJSONObject: body))
    }

    private func signIn(path: String, body: Data) async throws -> MinutesCloudSession {
        let (data, response) = try await send("POST", path, body: body, authorized: false)
        guard let token = response.value(forHTTPHeaderField: "set-auth-token"), !token.isEmpty else {
            throw MinutesCloudError.invalidResponse("ログインの印（set-auth-token）がない")
        }
        struct Body: Decodable {
            struct User: Decodable {
                var id: String?
                var email: String?
            }

            var user: User?
        }
        let user = (try? JSONCoding.decoder().decode(Body.self, from: data))?.user
        return MinutesCloudSession(token: token, userID: user?.id, email: user?.email)
    }

    // MARK: アカウント

    public func account() async throws -> MinutesCloudAccount {
        try decode(MinutesCloudAccount.self, from: try await send("GET", "/v1/me").0)
    }

    // MARK: 文字起こし

    public func createRecording(_ request: MinutesCloudRecordingRequest) async throws -> MinutesCloudRecording {
        try decode(RecordingEnvelope.self, from: try await send("POST", "/v1/recordings", body: try JSONCoding.encoder(pretty: false).encode(request)).0).recording
    }

    public func uploadAudio(recordingID: String, fileURL: URL, contentType: String) async throws {
        var request = try makeRequest("PUT", "/v1/recordings/\(recordingID)/audio")
        request.setValue(contentType, forHTTPHeaderField: "content-type")
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        _ = try check(data, response)
    }

    /// 上げ終わりを知らせて処理を始めてもらう。区切りで上げたときは、走ごとのバイト数（runs）を添える（届いていない区切りがあれば 400 parts_missing）。
    public func complete(recordingID: String, durationSeconds: Double?, runs: [MinutesCloudRunBytes]? = nil) async throws -> MinutesCloudRecording {
        try decode(RecordingEnvelope.self, from: try await send("POST", "/v1/recordings/\(recordingID)/complete", body: try Self.completeBody(durationSeconds: durationSeconds, runs: runs)).0).recording
    }

    /// complete の本文（裏の URLSession で送るときはファイルにして使う）。
    public static func completeBody(durationSeconds: Double?, runs: [MinutesCloudRunBytes]?) throws -> Data {
        struct Body: Encodable {
            var durationSeconds: Double?
            var runs: [MinutesCloudRunBytes]?
        }
        return try JSONCoding.encoder(pretty: false).encode(Body(durationSeconds: durationSeconds, runs: runs))
    }

    public func recording(id: String) async throws -> MinutesCloudRecording {
        try decode(RecordingEnvelope.self, from: try await send("GET", "/v1/recordings/\(id)").0).recording
    }

    /// この利用者の録音（新しい順に 100 件）。
    public func recordings() async throws -> [MinutesCloudRecording] {
        struct Envelope: Decodable {
            var recordings: [MinutesCloudRecording]
        }
        return try decode(Envelope.self, from: try await send("GET", "/v1/recordings").0).recordings
    }

    /// 区切りを上げる要求（PUT /v1/recordings/:id/parts/:run/:offset）。裏の URLSession の uploadTask(with:fromFile:) にそのまま使える。
    public func partUploadRequest(recordingID: String, run: Int, offset: Int, contentType: String) throws -> URLRequest {
        var request = try makeRequest("PUT", "/v1/recordings/\(recordingID)/parts/\(run)/\(offset)")
        request.setValue(contentType, forHTTPHeaderField: "content-type")
        return request
    }

    /// 録音を作る要求と本文（裏の URLSession で、本文をファイルにして送るときに使う）。
    public func createRecordingRequest() throws -> URLRequest {
        var request = try makeRequest("POST", "/v1/recordings")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    public static func createRecordingBody(_ request: MinutesCloudRecordingRequest) throws -> Data {
        try JSONCoding.encoder(pretty: false).encode(request)
    }

    /// 裏の URLSession で受けた応答の本文から録音を読む（{"recording": …}）。
    public static func decodeRecording(from data: Data) throws -> MinutesCloudRecording {
        do {
            return try JSONCoding.decoder().decode(RecordingEnvelope.self, from: data).recording
        } catch {
            throw MinutesCloudError.invalidResponse("MinutesCloudRecording: \(error)")
        }
    }

    /// 応答の本文の誤りの名前（{"error": "<code>"} か {"code": "<CODE>"}）。
    public static func errorCode(from data: Data) -> String? {
        struct Failure: Decodable {
            var error: String?
            var code: String?
        }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        return failure?.error ?? failure?.code
    }

    /// complete の要求（本文は completeBody）。裏の URLSession で送るときに使う。
    public func completeRequest(recordingID: String) throws -> URLRequest {
        var request = try makeRequest("POST", "/v1/recordings/\(recordingID)/complete")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    public func uploadPart(recordingID: String, run: Int, offset: Int, fileURL: URL, contentType: String) async throws {
        let request = try partUploadRequest(recordingID: recordingID, run: run, offset: offset, contentType: contentType)
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        _ = try check(data, response)
    }

    /// 文字起こし（transcript.json。Mac の TranscriptDocument と同じ形）。できる前は 404 not_ready。
    public func transcript(recordingID: String) async throws -> TranscriptDocument {
        try decode(TranscriptDocument.self, from: try await send("GET", "/v1/recordings/\(recordingID)/transcript").0)
    }

    /// 議事録（summary.json。Mac の MinutesSummary と同じ形）。できる前は 404 not_ready。
    public func summary(recordingID: String) async throws -> MinutesSummary {
        try decode(MinutesSummary.self, from: try await send("GET", "/v1/recordings/\(recordingID)/summary").0)
    }

    /// 音声を destination に置く（保存の期間を過ぎていれば 404 audio_not_available）。
    public func downloadAudio(recordingID: String, to destination: URL) async throws {
        let request = try makeRequest("GET", "/v1/recordings/\(recordingID)/audio")
        let (location, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: location) }
        guard let http = response as? HTTPURLResponse else { throw MinutesCloudError.invalidResponse("HTTP の応答ではない") }
        guard (200..<300).contains(http.statusCode) else {
            _ = try check((try? Data(contentsOf: location)) ?? Data(), response)
            return
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: location, to: destination)
    }

    /// 会議の題名と話者の名前を直す（PATCH /v1/recordings/:id、iPhone・Watch）。title が nil なら変えない（空なら消す）。
    /// speakerNames はラベル（"spk_0" など）→ 名前（空なら消す）。話者の名前は文字起こしのあとだけ（前は 409 not_ready）。
    public func updateRecording(id: String, title: String? = nil, speakerNames: [String: String]? = nil) async throws -> MinutesCloudRecording {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let speakerNames { body["speaker_names"] = speakerNames }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try decode(RecordingEnvelope.self, from: try await send("PATCH", "/v1/recordings/\(id)", body: data).0).recording
    }

    public func deleteRecording(id: String) async throws {
        _ = try await send("DELETE", "/v1/recordings/\(id)")
    }

    /// ElevenLabs の文字起こしそのもの（ElevenLabsScribe.parseResponse で読む）。
    public func transcription(recordingID: String) async throws -> Data {
        try await send("GET", "/v1/recordings/\(recordingID)/stt").0
    }

    // MARK: 閲覧用のリンク（P7）

    /// リンクを作る。includeTranscript が false なら要約だけ（要約がなければ 409 no_summary）。expiresInDays は 1〜365。
    /// 処理が終わる前は 409 not_ready、有料でなければ 402 no_plan、1 つの会議で使えるリンクは 20 まで（409 too_many_shares）。
    public func createShare(recordingID: String, includeTranscript: Bool = false, expiresInDays: Int = MinutesCloudShare.defaultExpiryDays) async throws -> MinutesCloudShare {
        let body = try JSONSerialization.data(withJSONObject: ["include_transcript": includeTranscript, "expires_in_days": expiresInDays])
        return try decode(ShareEnvelope.self, from: try await send("POST", "/v1/recordings/\(recordingID)/shares", body: body).0).share
    }

    /// 使えるリンク（期限の内、新しい順）。
    public func shares(recordingID: String) async throws -> [MinutesCloudShare] {
        try decode(SharesEnvelope.self, from: try await send("GET", "/v1/recordings/\(recordingID)/shares").0).shares
    }

    /// リンクを取り消す（すぐに読めなくなる）。もうない（404）なら、取り消し済みとみなす。
    public func revokeShare(recordingID: String, shareID: String) async throws {
        do {
            _ = try await send("DELETE", "/v1/recordings/\(recordingID)/shares/\(shareID)")
        } catch let error as MinutesCloudError where error.status == 404 {
            return
        }
    }

    // MARK: 要約

    public func createSummary(clientID: String, group: String, timeZone: String = TimeZone.current.identifier, input: SummaryInput) async throws -> MinutesCloudSummaryJob {
        struct Body: Encodable {
            var clientId: String
            var group: String
            var timeZone: String
            var input: SummaryInput
        }
        let body = try JSONCoding.encoder(pretty: false).encode(Body(clientId: clientID, group: group, timeZone: timeZone, input: input))
        return try decode(SummaryEnvelope.self, from: try await send("POST", "/v1/summaries", body: body).0).summary
    }

    public func summary(id: String) async throws -> MinutesCloudSummaryJob {
        try decode(SummaryEnvelope.self, from: try await send("GET", "/v1/summaries/\(id)").0).summary
    }

    // MARK: 共通

    private struct RecordingEnvelope: Decodable {
        var recording: MinutesCloudRecording
    }

    private struct SummaryEnvelope: Decodable {
        var summary: MinutesCloudSummaryJob
    }

    private struct ShareEnvelope: Decodable {
        var share: MinutesCloudShare
    }

    private struct SharesEnvelope: Decodable {
        var shares: [MinutesCloudShare]
    }

    private func makeRequest(_ method: String, _ path: String, authorized: Bool = true) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let language = Locale.preferredLanguages.first { request.setValue(language, forHTTPHeaderField: "accept-language") }
        if authorized {
            guard let token = token(), !token.isEmpty else { throw MinutesCloudError.notSignedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
        return request
    }

    private func send(_ method: String, _ path: String, json: [String: String], authorized: Bool = true) async throws -> (Data, HTTPURLResponse) {
        try await send(method, path, body: try JSONSerialization.data(withJSONObject: json), authorized: authorized)
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, authorized: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(method, path, authorized: authorized)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let (data, response) = try await session.data(for: request)
        return try check(data, response)
    }

    private func check(_ data: Data, _ response: URLResponse) throws -> (Data, HTTPURLResponse) {
        guard let http = response as? HTTPURLResponse else { throw MinutesCloudError.invalidResponse("HTTP の応答ではない") }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable {
                var error: String?
                var code: String?
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw MinutesCloudError.http(status: http.statusCode, code: failure?.error ?? failure?.code, requestID: http.value(forHTTPHeaderField: "cf-ray"))
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONCoding.decoder().decode(type, from: data)
        } catch {
            throw MinutesCloudError.invalidResponse("\(T.self): \(error)")
        }
    }
}
