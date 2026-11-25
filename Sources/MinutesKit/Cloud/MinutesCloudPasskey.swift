import Foundation

// パスキー（WebAuthn）。サーバー（Better Auth の passkey 1.7.27、@simplewebauthn/server 13）とやり取りする形と、
// AuthenticationServices の結果を WebAuthn の JSON（base64url）にする部分。ASAuthorization を呼ぶのはアプリの側（iPhone）。
// 形（2026-11-25、@better-auth/passkey 1.7.27 のソースで確かめた。サーバーの README の表）:
//   作る: GET /v1/auth/passkey/generate-register-options（Bearer。作ってから 1 日以内のセッションだけ。古いと 403 SESSION_NOT_FRESH）
//         → POST /v1/auth/passkey/verify-registration {response, name}
//   ログイン: GET /v1/auth/passkey/generate-authenticate-options（印なし。allowCredentials なし＝端末にあるパスキーから選ぶ）
//         → POST /v1/auth/passkey/verify-authentication {response}（応答の見出し set-auth-token が印。知らないパスキーは 401 PASSKEY_NOT_FOUND）
//   一覧: GET /v1/auth/passkey/list-user-passkeys、消す: POST /v1/auth/passkey/delete-passkey {id}
// challenge はサーバーが Cookie（名前の終わりが better-auth-passkey、5 分）で持ち回る。URLSession には Cookie を持たせず
// （URLSession.minutesCloud）、準備の応答の Set-Cookie を、確かめの要求の Cookie の見出しにそのまま渡す。
// Cookie を伴う要求には Origin が要る（Better Auth の CSRF の確かめ）ので、パスキーの origin（https://minutes.tools）を付ける。

public enum MinutesCloudPasskeys {
    /// RP ID（サーバーの PASSKEY_RP_ID と、アプリの関連ドメイン webcredentials:minutes.tools と同じ）
    public static let relyingPartyID = "minutes.tools"
    /// Cookie を伴う確かめの要求に付ける Origin（サーバーの PASSKEY_ORIGINS）。iOS は関連ドメインのアプリの clientDataJSON にも、この値を入れる
    public static let origin = "https://minutes.tools"
    /// challenge の Cookie の名前の終わり（本番は __Secure-better-auth.better-auth-passkey）
    static let challengeCookieSuffix = "better-auth-passkey"

    /// 準備の応答から、challenge の Cookie を「名前=値」で取り出す（確かめの要求の Cookie の見出しにする）。
    public static func challengeCookie(from response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "Set-Cookie"), let url = response.url else { return nil }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url)
        guard let cookie = cookies.first(where: { $0.name.hasSuffix(challengeCookieSuffix) }), !cookie.value.isEmpty else { return nil }
        return "\(cookie.name)=\(cookie.value)"
    }

    /// base64url（WebAuthn の JSON の書き方。= で埋めない）
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url を読む（= の埋めがあってもなくてもよい）。読めなければ nil
    public static func data(base64URL text: String) -> Data? {
        var base64 = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 = base64.replacingOccurrences(of: "=", with: "")
        switch base64.count % 4 {
        case 1: return nil
        case 2: base64 += "=="
        case 3: base64 += "="
        default: break
        }
        return Data(base64Encoded: base64)
    }
}

/// サーバーが出した準備と、確かめの要求に付けて返す Cookie（5 分で切れる）。
public struct MinutesCloudPasskeyCeremony<Options: Sendable & Equatable>: Sendable, Equatable {
    public var options: Options
    public var cookie: String

    public init(options: Options, cookie: String) {
        self.options = options
        self.cookie = cookie
    }
}

/// パスキーの ID（base64url）。作るときに除く一覧・ログインで選べる一覧に出る。
public struct MinutesCloudPasskeyDescriptor: Decodable, Sendable, Equatable {
    public var id: String

    public init(id: String) {
        self.id = id
    }

    public var idData: Data? { MinutesCloudPasskeys.data(base64URL: id) }
}

/// パスキーを作る準備（PublicKeyCredentialCreationOptionsJSON のうち、AuthenticationServices に渡すもの）。
public struct MinutesCloudPasskeyCreationOptions: Decodable, Sendable, Equatable {
    public struct RelyingParty: Decodable, Sendable, Equatable {
        public var id: String?
        public var name: String?
    }

    public struct User: Decodable, Sendable, Equatable {
        /// WebAuthn の user handle（base64url）。サーバーが作るたびに決める
        public var id: String
        /// パスキーの一覧（iOS の「パスワード」）に出る名前。サーバーはアカウントのメールアドレスを入れる
        public var name: String
        public var displayName: String?
    }

    public struct Selection: Decodable, Sendable, Equatable {
        public var userVerification: String?
    }

    /// base64url
    public var challenge: String
    public var rp: RelyingParty
    public var user: User
    /// このアカウントのパスキー（同じ iCloud キーチェーンに 2 つ作らないため）
    public var excludeCredentials: [MinutesCloudPasskeyDescriptor]?
    public var authenticatorSelection: Selection?
    public var attestation: String?

    public var challengeData: Data? { MinutesCloudPasskeys.data(base64URL: challenge) }
    public var userIDData: Data? { MinutesCloudPasskeys.data(base64URL: user.id) }
    public var relyingPartyID: String { rp.id ?? MinutesCloudPasskeys.relyingPartyID }
    public var excludedCredentialIDs: [Data] { (excludeCredentials ?? []).compactMap(\.idData) }
}

/// パスキーでログインする準備（PublicKeyCredentialRequestOptionsJSON）。
public struct MinutesCloudPasskeyRequestOptions: Decodable, Sendable, Equatable {
    /// base64url
    public var challenge: String
    public var rpId: String?
    /// 印なしで頼むので、ふつうは空（端末にあるパスキーから選ぶ）
    public var allowCredentials: [MinutesCloudPasskeyDescriptor]?
    public var userVerification: String?

    public var challengeData: Data? { MinutesCloudPasskeys.data(base64URL: challenge) }
    public var relyingPartyID: String { rpId ?? MinutesCloudPasskeys.relyingPartyID }
}

/// パスキーをどこで確かめたか（WebAuthn の authenticatorAttachment）。近くのほかの端末（QR）なら crossPlatform。
public enum MinutesCloudPasskeyAttachment: String, Sendable, Equatable {
    case platform
    case crossPlatform = "cross-platform"
}

/// 作ったパスキー（ASAuthorizationPlatformPublicKeyCredentialRegistration の中身）。
public struct MinutesCloudPasskeyRegistration: Sendable, Equatable {
    public var credentialID: Data
    public var clientDataJSON: Data
    public var attestationObject: Data
    public var attachment: MinutesCloudPasskeyAttachment?

    public init(credentialID: Data, clientDataJSON: Data, attestationObject: Data, attachment: MinutesCloudPasskeyAttachment?) {
        self.credentialID = credentialID
        self.clientDataJSON = clientDataJSON
        self.attestationObject = attestationObject
        self.attachment = attachment
    }

    /// verify-registration の本文 {response: RegistrationResponseJSON, name}。name は一覧に出す名前（端末の種類）
    public func verificationBody(name: String) throws -> Data {
        let id = MinutesCloudPasskeys.base64URL(credentialID)
        var response: [String: Any] = [
            "id": id,
            "rawId": id,
            "type": "public-key",
            "response": [
                "clientDataJSON": MinutesCloudPasskeys.base64URL(clientDataJSON),
                "attestationObject": MinutesCloudPasskeys.base64URL(attestationObject),
            ],
            "clientExtensionResults": [String: Any](),
        ]
        if let attachment { response["authenticatorAttachment"] = attachment.rawValue }
        return try JSONSerialization.data(withJSONObject: ["response": response, "name": name], options: [.sortedKeys])
    }
}

/// パスキーでの確かめ（ASAuthorizationPlatformPublicKeyCredentialAssertion の中身）。
public struct MinutesCloudPasskeyAssertion: Sendable, Equatable {
    public var credentialID: Data
    public var clientDataJSON: Data
    public var authenticatorData: Data
    public var signature: Data
    public var userHandle: Data?
    public var attachment: MinutesCloudPasskeyAttachment?

    public init(credentialID: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data?, attachment: MinutesCloudPasskeyAttachment?) {
        self.credentialID = credentialID
        self.clientDataJSON = clientDataJSON
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.userHandle = userHandle
        self.attachment = attachment
    }

    /// verify-authentication の本文 {response: AuthenticationResponseJSON}
    public func verificationBody() throws -> Data {
        let id = MinutesCloudPasskeys.base64URL(credentialID)
        var inner: [String: Any] = [
            "clientDataJSON": MinutesCloudPasskeys.base64URL(clientDataJSON),
            "authenticatorData": MinutesCloudPasskeys.base64URL(authenticatorData),
            "signature": MinutesCloudPasskeys.base64URL(signature),
        ]
        if let userHandle { inner["userHandle"] = MinutesCloudPasskeys.base64URL(userHandle) }
        var response: [String: Any] = [
            "id": id,
            "rawId": id,
            "type": "public-key",
            "response": inner,
            "clientExtensionResults": [String: Any](),
        ]
        if let attachment { response["authenticatorAttachment"] = attachment.rawValue }
        return try JSONSerialization.data(withJSONObject: ["response": response], options: [.sortedKeys])
    }
}

/// アカウントのパスキー（一覧）。サーバーの表 passkeys のうち、画面と端末への知らせ（ASCredentialUpdater）に使うもの。
public struct MinutesCloudPasskey: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    /// 作ったときに付けた名前（端末の種類。「iPhone」）
    public var name: String?
    /// base64url
    public var credentialID: String
    public var createdAt: Date?
    /// singleDevice（その端末だけ）か multiDevice（iCloud キーチェーンなどで同期する）
    public var deviceType: String?

    public init(id: String, name: String?, credentialID: String, createdAt: Date?, deviceType: String?) {
        self.id = id
        self.name = name
        self.credentialID = credentialID
        self.createdAt = createdAt
        self.deviceType = deviceType
    }

    public var credentialIDData: Data? { MinutesCloudPasskeys.data(base64URL: credentialID) }
    /// 同じ Apple アカウントのほかの端末にも届くパスキー
    public var isSynced: Bool { deviceType == "multiDevice" }
}
