import Foundation
import Synchronization

/// Minutes（キーなし）のログインの印（SPEC §5.6、§14）。Keychain（service jp.pictors.minutes、account minutes-cloud-session）に置き、起動中は覚えておく
/// （Keychain の読み取りは、署名の違う版では確認のダイアログを出すので、1 回だけ読む）。
/// テストと CLI は環境変数 MINUTES_CLOUD_TOKEN で差し替えられる。印・メールアドレスはログに出さない。
public enum MinutesCloudCredentials {
    public static let tokenAccount = "minutes-cloud-session"
    /// 表示用のログイン中のメールアドレス
    public static let emailAccount = "minutes-cloud-email"
    public static let tokenEnvName = "MINUTES_CLOUD_TOKEN"
    public static let baseURLEnvName = "MINUTES_CLOUD_BASE_URL"

    private struct Loaded {
        var token: String?
        var email: String?
    }

    private static let cache = Mutex<Loaded?>(nil)

    private static func loaded() -> Loaded {
        cache.withLock { cache in
            if let cache { return cache }
            let value = Loaded(token: try? KeychainStore.get(account: tokenAccount), email: try? KeychainStore.get(account: emailAccount))
            cache = value
            return value
        }
    }

    /// ログインの印（なければ nil）。
    public static func token() -> String? {
        if let token = ProcessInfo.processInfo.environment[tokenEnvName], !token.isEmpty { return token }
        return loaded().token
    }

    /// ログイン中のメールアドレス（表示用）。
    public static func email() -> String? { loaded().email }

    public static var isSignedIn: Bool { token() != nil }

    public static func save(_ session: MinutesCloudSession, email: String) throws {
        try KeychainStore.set(session.token, account: tokenAccount)
        try KeychainStore.set(email, account: emailAccount)
        cache.withLock { $0 = Loaded(token: session.token, email: email) }
    }

    public static func clear() throws {
        try KeychainStore.delete(account: tokenAccount)
        try KeychainStore.delete(account: emailAccount)
        cache.withLock { $0 = Loaded(token: nil, email: nil) }
    }
}

public extension MinutesCloudClient {
    /// アプリと CLI が使うもの（印は Keychain。サーバーの場所は環境変数 MINUTES_CLOUD_BASE_URL で手元のサーバーなどに向けられる）。
    static func standard() -> MinutesCloudClient {
        let base = ProcessInfo.processInfo.environment[MinutesCloudCredentials.baseURLEnvName].flatMap(URL.init(string:)) ?? productionBaseURL
        return MinutesCloudClient(baseURL: base, token: { MinutesCloudCredentials.token() })
    }
}
