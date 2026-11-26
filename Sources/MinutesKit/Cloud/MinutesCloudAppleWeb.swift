import CryptoKit
import Foundation

// Sign in with Apple のウェブの流れ（Mac のアプリ、SPEC §5.6）。Developer ID で配る Mac のアプリはネイティブの Sign in with Apple を
// 使えないので、ブラウザ（ASWebAuthenticationSession）で Apple のページを通す。サーバーとの約束（サーバーの src/auth/apple-web.ts）:
//   1. ブラウザで GET /v1/auth/apple/web/start?challenge=<verifier の SHA-256、base64url> を開く（サーバーが Apple のページへ送る）
//   2. 終わると、ブラウザが jp.pictors.minutes.auth://apple?code=<一度だけのコード>（だめなら ?error=cancelled か failed）へ戻る
//   3. POST /v1/auth/apple/web/token {code, verifier} → 応答の見出し set-auth-token が印（MinutesCloudClient.signInWithAppleWeb）
// verifier はこの Mac から出さない（3 で初めて送る）ので、戻りの URL をほかのアプリが横取りしても、コードだけでは入れない。
// ここは URL の組み立てと戻りの読み取りだけ。ASWebAuthenticationSession を呼ぶのはアプリの側。

/// 1 回のログインの試み。試みごとに作り直す。
public struct MinutesCloudAppleWeb: Sendable, Equatable {
    /// 戻りの URL のスキーム（ASWebAuthenticationSession が受ける。アプリの URL スキームには登録しない）
    public static let callbackScheme = "jp.pictors.minutes.auth"

    /// サーバーへ最後に送る値（43 文字、base64url）
    public let verifier: String
    /// ブラウザに渡す値（verifier の SHA-256、base64url）
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 バイトの乱数から作る。
    public static func make() -> MinutesCloudAppleWeb {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return MinutesCloudAppleWeb(verifier: base64url(Data(bytes)))
    }

    /// ブラウザで開く URL。
    public func startURL(baseURL: URL) -> URL {
        baseURL.appending(path: "/v1/auth/apple/web/start").appending(queryItems: [URLQueryItem(name: "challenge", value: challenge)])
    }

    public enum CallbackError: Error, Equatable {
        /// 利用者が Apple のページで断った
        case cancelled
        /// サーバーか Apple が断った（理由はサーバーのログに残る。アプリには出さない）
        case failed
        /// 戻りの URL の形が違う
        case malformed
    }

    /// 戻りの URL から一度だけのコードを読む。
    public static func code(fromCallback url: URL) throws -> String {
        guard url.scheme?.lowercased() == callbackScheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw CallbackError.malformed
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw error == "cancelled" ? CallbackError.cancelled : CallbackError.failed
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw CallbackError.malformed }
        return code
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
