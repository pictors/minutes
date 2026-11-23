import CryptoKit
import Foundation

// Pictors のサーバー（Minutes のキーなし。自分の API キーなしで文字起こしと要約を使う有料の手段）とのやり取り。
// Mac・iPhone・Watch で共通（SPEC §5.6）。ログインの印（Bearer）は呼び出し側が持ち、ここでは保存しない。Cookie は使わない。
// API の形（2026-11-23 確認）: サーバーの docs/mac-keyless.md（非公開）と同じもの。
//   ログイン: POST /v1/auth/email-otp/send-verification-otp {email, type: "sign-in"} → POST /v1/auth/sign-in/email-otp {email, otp}
//            （応答の見出し set-auth-token が印）、POST /v1/auth/sign-in/email {email, password}、POST /v1/auth/sign-out
//   アカウント: GET /v1/me → {user:{id}, plan, usage:{seconds_this_month, seconds_pending, seconds_limit}}
//   文字起こし: POST /v1/recordings（summarize=false・diarize・keyterms・group）→ PUT /v1/recordings/:id/audio → POST /complete
//             → GET /v1/recordings/:id（status: uploading・queued・transcribing・summarizing・done・failed）→ GET /stt（ElevenLabs の応答の形）
//   要約: POST /v1/summaries {client_id, group, time_zone, input: SummaryInput} → GET /v1/summaries/:id（status・result）
//   誤り: {"error": "<code>"}（ログインの入口は {"code": "<CODE>", "message": …}）。401 は印がない・切れた

/// サーバーの場所と、Cookie を使わない URLSession。
public extension URLSession {
    /// キーなしのサーバー用。Cookie も応答の写しも持たない（印は Authorization: Bearer で送る）。
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
            return "Minutes にログインしていません（設定 > プロバイダ の「Minutes（キーなし）」でログインしてください）"
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
        case "limit_exceeded": return "今月のキーなしで使える量を超えました"
        case "no_plan": return "キーなしの文字起こしと要約は、有料のプランで使えます"
        case "no_transcription": return "キーなしの要約は、キーなしで文字起こしした会議（30 日以内）だけで使えます"
        case "too_many_summaries": return "この会議のキーなしの要約は、もう作り直せません（10 回まで）"
        case "group_full": return "この会議はキーなしでもう送れません（同じ会議の録音は 2 本まで）"
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

public struct MinutesCloudRecording: Decodable, Sendable, Equatable {
    public var id: String
    public var clientId: String
    /// uploading・queued・transcribing・summarizing・done・failed
    public var status: String
    public var error: String?
    public var durationSeconds: Double?
    public var group: String?

    public var isFinished: Bool { status == "done" || status == "failed" }
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

/// Pictors のサーバーとのやり取り。
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

    /// この端末のログインを取り消す（印はサーバーで使えなくなる）。
    public func signOut() async throws {
        _ = try await send("POST", "/v1/auth/sign-out", json: [String: String]())
    }

    private func signIn(path: String, body: [String: String]) async throws -> MinutesCloudSession {
        let (data, response) = try await send("POST", path, json: body, authorized: false)
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

    public func complete(recordingID: String, durationSeconds: Double?) async throws -> MinutesCloudRecording {
        var body: [String: Double] = [:]
        if let durationSeconds { body["duration_seconds"] = durationSeconds }
        return try decode(RecordingEnvelope.self, from: try await send("POST", "/v1/recordings/\(recordingID)/complete", json: body).0).recording
    }

    public func recording(id: String) async throws -> MinutesCloudRecording {
        try decode(RecordingEnvelope.self, from: try await send("GET", "/v1/recordings/\(id)").0).recording
    }

    public func deleteRecording(id: String) async throws {
        _ = try await send("DELETE", "/v1/recordings/\(id)")
    }

    /// ElevenLabs の文字起こしそのもの（ElevenLabsScribe.parseResponse で読む）。
    public func transcription(recordingID: String) async throws -> Data {
        try await send("GET", "/v1/recordings/\(recordingID)/stt").0
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

    private func send(_ method: String, _ path: String, json: [String: Double]) async throws -> (Data, HTTPURLResponse) {
        try await send(method, path, body: try JSONSerialization.data(withJSONObject: json))
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
