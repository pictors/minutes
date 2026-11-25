import Foundation
@testable import MinutesKit
import Synchronization
import Testing

/// パスキー（SPEC §5.7）: サーバー（Better Auth の passkey 1.7.27・@simplewebauthn/server 13）とやり取りする形。
/// challenge の Cookie を見出しで持ち回り、Origin を付け、WebAuthn の JSON を base64url で書く。
@Suite("Minutes クラウドのパスキー")
struct MinutesCloudPasskeyTests {
    private static func answer(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> (status: Int, headers: [String: String], body: Data) {
        (status, ["content-type": "application/json"].merging(headers) { $1 }, try! JSONSerialization.data(withJSONObject: object))
    }

    private static func object(_ data: Data?) -> [String: Any] {
        (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    /// 本番と同じ形の challenge の Cookie（署名つきの値は URL の形で書かれる）
    private static let challengeSetCookie = "__Secure-better-auth.better-auth-passkey=fictionalToken.fictionalSignature%3D; Max-Age=300; Path=/; HttpOnly; Secure; SameSite=Lax"
    private static let challengeCookie = "__Secure-better-auth.better-auth-passkey=fictionalToken.fictionalSignature%3D"

    @Test("base64url: + / = を使わずに書き、埋めがあってもなくても読む。長さの合わないものは読まない")
    func base64URL() {
        let bytes = Data([0xFB, 0xFF, 0xBF, 0x00, 0x01])
        #expect(MinutesCloudPasskeys.base64URL(bytes) == "-_-_AAE")
        #expect(MinutesCloudPasskeys.data(base64URL: "-_-_AAE") == bytes)
        #expect(MinutesCloudPasskeys.data(base64URL: "-_-_AAE=") == bytes)
        #expect(MinutesCloudPasskeys.data(base64URL: "") == Data())
        #expect(MinutesCloudPasskeys.data(base64URL: "A") == nil)
        let random = Data((0..<97).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
        #expect(MinutesCloudPasskeys.data(base64URL: MinutesCloudPasskeys.base64URL(random)) == random)
    }

    @Test("challenge の Cookie を Set-Cookie から「名前=値」で取り出す。ほかの Cookie が並んでいても、なければ nil")
    func challengeCookie() throws {
        let url = URL(string: "https://api.minutes.tools/v1/auth/passkey/generate-authenticate-options")!
        let single = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Set-Cookie": Self.challengeSetCookie]))
        #expect(MinutesCloudPasskeys.challengeCookie(from: single) == Self.challengeCookie)

        // 複数の Set-Cookie は 1 つの見出しに「, 」でつながって届く（Expires の中にも「, 」がある）
        let joined = "other=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/, " + Self.challengeSetCookie
        let several = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Set-Cookie": joined]))
        #expect(MinutesCloudPasskeys.challengeCookie(from: several) == Self.challengeCookie)

        let none = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Set-Cookie": "other=1; Path=/"]))
        #expect(MinutesCloudPasskeys.challengeCookie(from: none) == nil)
    }

    @Test("作る準備を読む: challenge と user handle は base64url のバイト列、除くパスキーの ID も読む")
    func creationOptions() throws {
        // @simplewebauthn/server の generateRegistrationOptions の形（値は架空）
        let json: [String: Any] = [
            "challenge": MinutesCloudPasskeys.base64URL(Data("fictional-challenge".utf8)),
            "rp": ["name": "Minutes", "id": "minutes.tools"],
            "user": ["id": MinutesCloudPasskeys.base64URL(Data("fictionaluserhandle".utf8)), "name": "someone@example.test", "displayName": "someone@example.test"],
            "pubKeyCredParams": [["alg": -8, "type": "public-key"], ["alg": -7, "type": "public-key"], ["alg": -257, "type": "public-key"]],
            "timeout": 60000,
            "attestation": "none",
            "excludeCredentials": [["id": MinutesCloudPasskeys.base64URL(Data([1, 2, 3])), "type": "public-key", "transports": ["internal", "hybrid"]]],
            "authenticatorSelection": ["residentKey": "preferred", "userVerification": "preferred", "requireResidentKey": false],
            "extensions": ["credProps": true],
            "hints": [],
        ]
        let options = try JSONCoding.decoder().decode(MinutesCloudPasskeyCreationOptions.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(options.challengeData == Data("fictional-challenge".utf8))
        #expect(options.userIDData == Data("fictionaluserhandle".utf8))
        #expect(options.user.name == "someone@example.test")
        #expect(options.relyingPartyID == "minutes.tools")
        #expect(options.excludedCredentialIDs == [Data([1, 2, 3])])
        #expect(options.authenticatorSelection?.userVerification == "preferred")
    }

    @Test("作ったパスキーの本文: RegistrationResponseJSON（id と rawId は同じ base64url）と名前")
    func registrationBody() throws {
        let registration = MinutesCloudPasskeyRegistration(credentialID: Data([0xFB, 0xFF, 0x01]), clientDataJSON: Data(#"{"type":"webauthn.create"}"#.utf8), attestationObject: Data([0xA3, 0x00]), attachment: .platform)
        let body = Self.object(try registration.verificationBody(name: "iPhone"))
        #expect(body["name"] as? String == "iPhone")
        let response = try #require(body["response"] as? [String: Any])
        #expect(response["id"] as? String == "-_8B")
        #expect(response["rawId"] as? String == "-_8B")
        #expect(response["type"] as? String == "public-key")
        #expect(response["authenticatorAttachment"] as? String == "platform")
        #expect((response["clientExtensionResults"] as? [String: Any])?.isEmpty == true)
        let inner = try #require(response["response"] as? [String: Any])
        #expect(inner["clientDataJSON"] as? String == MinutesCloudPasskeys.base64URL(Data(#"{"type":"webauthn.create"}"#.utf8)))
        #expect(inner["attestationObject"] as? String == "owA")
    }

    @Test("確かめの本文: AuthenticationResponseJSON。userHandle は端末が返したときだけ、近くの端末で確かめたら cross-platform")
    func assertionBody() throws {
        let withHandle = MinutesCloudPasskeyAssertion(credentialID: Data([9]), clientDataJSON: Data("c".utf8), authenticatorData: Data("a".utf8), signature: Data("s".utf8), userHandle: Data("u".utf8), attachment: .crossPlatform)
        let response = try #require(Self.object(try withHandle.verificationBody())["response"] as? [String: Any])
        #expect(response["id"] as? String == "CQ")
        #expect(response["authenticatorAttachment"] as? String == "cross-platform")
        let inner = try #require(response["response"] as? [String: Any])
        #expect(inner["clientDataJSON"] as? String == "Yw")
        #expect(inner["authenticatorData"] as? String == "YQ")
        #expect(inner["signature"] as? String == "cw")
        #expect(inner["userHandle"] as? String == "dQ")

        let withoutHandle = MinutesCloudPasskeyAssertion(credentialID: Data([9]), clientDataJSON: Data("c".utf8), authenticatorData: Data("a".utf8), signature: Data("s".utf8), userHandle: nil, attachment: nil)
        let bare = try #require(Self.object(try withoutHandle.verificationBody())["response"] as? [String: Any])
        #expect((bare["response"] as? [String: Any])?["userHandle"] == nil)
        #expect(bare["authenticatorAttachment"] == nil)
    }

    @Test("パスキーでログイン: 準備は印なし、確かめは Cookie と Origin を付けて印なしで送り、印は set-auth-token から取る")
    func signInWithPasskey() async throws {
        let seen = Mutex<[StubURLProtocol.Request]>([])
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append(request) }
            switch request.path {
            case "/v1/auth/passkey/generate-authenticate-options":
                return Self.answer(["challenge": MinutesCloudPasskeys.base64URL(Data("fictional-challenge".utf8)), "rpId": "minutes.tools", "userVerification": "preferred", "timeout": 60000], headers: ["Set-Cookie": Self.challengeSetCookie])
            case "/v1/auth/passkey/verify-authentication":
                return Self.answer(["session": ["id": "s1"], "user": ["id": "u1", "email": "someone@example.test"]], headers: ["set-auth-token": "fictional-session-token"])
            default:
                return Self.answer(["code": "NOT_FOUND"], status: 404)
            }
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "token-that-must-not-be-sent" })
        let ceremony = try await client.passkeySignInOptions()
        #expect(ceremony.cookie == Self.challengeCookie)
        #expect(ceremony.options.challengeData == Data("fictional-challenge".utf8))
        #expect(ceremony.options.relyingPartyID == "minutes.tools")

        let assertion = MinutesCloudPasskeyAssertion(credentialID: Data([7]), clientDataJSON: Data("c".utf8), authenticatorData: Data("a".utf8), signature: Data("s".utf8), userHandle: nil, attachment: .platform)
        let session = try await client.signIn(passkey: assertion, cookie: ceremony.cookie)
        #expect(session == MinutesCloudSession(token: "fictional-session-token", userID: "u1", email: "someone@example.test"))

        let requests = seen.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests[0].method == "GET")
        #expect(requests[0].headers["authorization"] == nil)
        #expect(requests[1].method == "POST")
        #expect(requests[1].headers["authorization"] == nil)
        #expect(requests[1].headers["cookie"] == Self.challengeCookie)
        #expect(requests[1].headers["origin"] == "https://minutes.tools")
        #expect((Self.object(requests[1].body)["response"] as? [String: Any])?["id"] as? String == "Bw")
    }

    @Test("パスキーを作る: 準備と確かめに Bearer の印を付け、確かめには Cookie と Origin も付ける。古いセッションは SESSION_NOT_FRESH")
    func registerPasskey() async throws {
        let seen = Mutex<[StubURLProtocol.Request]>([])
        let fresh = Mutex(true)
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append(request) }
            switch request.path {
            case "/v1/auth/passkey/generate-register-options":
                guard fresh.withLock({ $0 }) else { return Self.answer(["code": "SESSION_NOT_FRESH", "message": "Session is not fresh"], status: 403) }
                return Self.answer([
                    "challenge": MinutesCloudPasskeys.base64URL(Data("fictional-challenge".utf8)),
                    "rp": ["name": "Minutes", "id": "minutes.tools"],
                    "user": ["id": MinutesCloudPasskeys.base64URL(Data("fictionaluserhandle".utf8)), "name": "someone@example.test", "displayName": "someone@example.test"],
                    "excludeCredentials": [],
                    "attestation": "none",
                ], headers: ["Set-Cookie": Self.challengeSetCookie])
            case "/v1/auth/passkey/verify-registration":
                return Self.answer(["id": "p1", "name": "iPhone", "credentialID": "Bw", "deviceType": "multiDevice", "backedUp": true])
            default:
                return Self.answer(["code": "NOT_FOUND"], status: 404)
            }
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" })
        let ceremony = try await client.passkeyCreationOptions()
        let registration = MinutesCloudPasskeyRegistration(credentialID: Data([7]), clientDataJSON: Data("c".utf8), attestationObject: Data("o".utf8), attachment: .platform)
        try await client.registerPasskey(registration, name: "iPhone", cookie: ceremony.cookie)

        let requests = seen.withLock { $0 }
        #expect(requests.map(\.headers["authorization"]) == ["Bearer fictional-token", "Bearer fictional-token"])
        #expect(requests[1].headers["cookie"] == Self.challengeCookie)
        #expect(requests[1].headers["origin"] == "https://minutes.tools")
        #expect(Self.object(requests[1].body)["name"] as? String == "iPhone")

        fresh.withLock { $0 = false }
        await #expect(throws: MinutesCloudError.http(status: 403, code: "SESSION_NOT_FRESH", requestID: nil)) {
            _ = try await client.passkeyCreationOptions()
        }
        #expect(MinutesCloudError.http(status: 403, code: "SESSION_NOT_FRESH", requestID: nil).localizedDescription.contains("もう一度ログイン"))
    }

    @Test("準備の応答に challenge の Cookie がなければ、確かめに進まない")
    func missingChallengeCookie() async throws {
        let base = StubURLProtocol.host { _ in Self.answer(["challenge": "AA", "rpId": "minutes.tools"]) }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { nil })
        let error = await #expect(throws: MinutesCloudError.self) {
            _ = try await client.passkeySignInOptions()
        }
        guard case .invalidResponse = error else {
            Issue.record("invalidResponse ではない: \(String(describing: error))")
            return
        }
    }

    @Test("アカウントにつないだログインの方法を読む（Apple の取り消しを、この端末で入った方法ではなくアカウントで決める）")
    func loginProviders() async throws {
        let seen = Mutex<StubURLProtocol.Request?>(nil)
        let base = StubURLProtocol.host { request in
            seen.withLock { $0 = request }
            return Self.answer([
                ["id": "a1", "providerId": "apple", "accountId": "fictional-apple-sub", "userId": "u1", "createdAt": "2026-11-25T10:00:00.000Z", "updatedAt": "2026-11-25T10:00:00.000Z", "scopes": []],
                ["id": "a2", "providerId": "credential", "accountId": "u1", "userId": "u1", "createdAt": "2026-11-25T10:00:00.000Z", "updatedAt": "2026-11-25T10:00:00.000Z", "scopes": []],
            ])
        }
        let providers = try await MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" }).loginProviders()
        #expect(providers == ["apple", "credential"])
        let request = try #require(seen.withLock { $0 })
        #expect(request.method == "GET")
        #expect(request.path == "/v1/auth/list-accounts")
        #expect(request.headers["authorization"] == "Bearer fictional-token")
    }

    @Test("一覧（ミリ秒つきの日時）と、消す（ID を送る）。サーバーにないパスキーでのログインは PASSKEY_NOT_FOUND")
    func listAndDelete() async throws {
        let seen = Mutex<[StubURLProtocol.Request]>([])
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append(request) }
            switch request.path {
            case "/v1/auth/passkey/list-user-passkeys":
                return (200, ["content-type": "application/json"], Data("""
                [{"id":"p1","name":"iPhone","publicKey":"pk","userId":"u1","credentialID":"-_8B","counter":0,"deviceType":"multiDevice","backedUp":true,"transports":null,"createdAt":"2026-11-25T10:00:00.123Z","aaguid":"00000000-0000-0000-0000-000000000000"}]
                """.utf8))
            case "/v1/auth/passkey/delete-passkey":
                return Self.answer(["status": true])
            case "/v1/auth/passkey/verify-authentication":
                return Self.answer(["code": "PASSKEY_NOT_FOUND", "message": "Passkey not found"], status: 401)
            default:
                return Self.answer(["code": "NOT_FOUND"], status: 404)
            }
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" })
        let passkeys = try await client.passkeys()
        #expect(passkeys.count == 1)
        #expect(passkeys[0].id == "p1")
        #expect(passkeys[0].name == "iPhone")
        #expect(passkeys[0].credentialIDData == Data([0xFB, 0xFF, 0x01]))
        #expect(passkeys[0].isSynced)
        #expect(passkeys[0].createdAt == JSONCoding.parseISO8601("2026-11-25T10:00:00.123Z"))

        try await client.deletePasskey(id: "p1")
        let delete = try #require(seen.withLock { $0.last })
        #expect(delete.method == "POST")
        #expect(Self.object(delete.body)["id"] as? String == "p1")

        let assertion = MinutesCloudPasskeyAssertion(credentialID: Data([7]), clientDataJSON: Data(), authenticatorData: Data(), signature: Data(), userHandle: nil, attachment: nil)
        await #expect(throws: MinutesCloudError.http(status: 401, code: "PASSKEY_NOT_FOUND", requestID: nil)) {
            _ = try await client.signIn(passkey: assertion, cookie: Self.challengeCookie)
        }
    }
}
