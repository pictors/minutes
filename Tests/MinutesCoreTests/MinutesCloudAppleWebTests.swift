import CryptoKit
import Foundation
@testable import MinutesKit
import Synchronization
import Testing

/// Sign in with Apple のウェブの流れ（Mac、SPEC §5.6）: サーバー（src/auth/apple-web.ts）と決めた URL と値の形。値は架空。
@Suite("Minutes クラウドの Apple でサインイン（ウェブの流れ）")
struct MinutesCloudAppleWebTests {
    @Test("challenge は verifier の SHA-256 の base64url（RFC 7636 の例と同じ値になる）")
    func challenge() {
        // RFC 7636 の付録 B の例
        let attempt = MinutesCloudAppleWeb(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(attempt.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("試みごとに違う verifier（43 文字、base64url）を作り、始めの URL には challenge だけを載せる")
    func make() throws {
        let first = MinutesCloudAppleWeb.make()
        let second = MinutesCloudAppleWeb.make()
        #expect(first.verifier != second.verifier)
        #expect(first.verifier.count == 43)
        #expect(first.verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        let url = first.startURL(baseURL: URL(string: "https://api.example.test")!)
        #expect(url.absoluteString == "https://api.example.test/v1/auth/apple/web/start?challenge=\(first.challenge)")
        #expect(!url.absoluteString.contains(first.verifier))
    }

    @Test("戻りの URL からコードを読む。断った・失敗・形の違うものは誤りにする")
    func callback() throws {
        #expect(try MinutesCloudAppleWeb.code(fromCallback: URL(string: "jp.pictors.minutes.auth://apple?code=fictional-code_123")!) == "fictional-code_123")
        #expect(throws: MinutesCloudAppleWeb.CallbackError.cancelled) {
            _ = try MinutesCloudAppleWeb.code(fromCallback: URL(string: "jp.pictors.minutes.auth://apple?error=cancelled")!)
        }
        #expect(throws: MinutesCloudAppleWeb.CallbackError.failed) {
            _ = try MinutesCloudAppleWeb.code(fromCallback: URL(string: "jp.pictors.minutes.auth://apple?error=failed")!)
        }
        // 誤りとコードの両方があれば、誤りを取る
        #expect(throws: MinutesCloudAppleWeb.CallbackError.failed) {
            _ = try MinutesCloudAppleWeb.code(fromCallback: URL(string: "jp.pictors.minutes.auth://apple?error=other&code=x")!)
        }
        #expect(throws: MinutesCloudAppleWeb.CallbackError.malformed) {
            _ = try MinutesCloudAppleWeb.code(fromCallback: URL(string: "jp.pictors.minutes.auth://apple")!)
        }
        #expect(throws: MinutesCloudAppleWeb.CallbackError.malformed) {
            _ = try MinutesCloudAppleWeb.code(fromCallback: URL(string: "minutes://apple?code=x")!)
        }
    }

    @Test("コードと verifier を送り、印は応答の見出し set-auth-token から取る（印なしで送る）")
    func exchange() async throws {
        let seen = Mutex<[StubURLProtocol.Request]>([])
        let base = StubURLProtocol.host { request in
            seen.withLock { $0.append(request) }
            let body = try! JSONSerialization.data(withJSONObject: ["user": ["id": "u1", "email": "kakuu@privaterelay.appleid.com"]])
            return (200, ["content-type": "application/json", "set-auth-token": "signed-token"], body)
        }
        let client = MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { nil })
        let session = try await client.signInWithAppleWeb(code: "fictional-code", verifier: "fictional-verifier")
        #expect(session == MinutesCloudSession(token: "signed-token", userID: "u1", email: "kakuu@privaterelay.appleid.com"))
        let request = try #require(seen.withLock { $0.first })
        #expect(request.method == "POST")
        #expect(request.path == "/v1/auth/apple/web/token")
        #expect(request.headers["authorization"] == nil && request.headers["Authorization"] == nil)
        let sent = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: String])
        #expect(sent == ["code": "fictional-code", "verifier": "fictional-verifier"])
    }
}
