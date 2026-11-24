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

    /// この Mac にログインの印が置いてあるか。中身は読まないので、署名の違う版（CLI など）が置いた印でも、読む許可の確認を出さない。
    /// 確認を断られると `isSignedIn` は false になるが、こちらは変わらない（選択肢を出すかどうかに使う）。
    public static var hasStoredLogin: Bool {
        if let token = ProcessInfo.processInfo.environment[tokenEnvName], !token.isEmpty { return true }
        return KeychainStore.exists(account: tokenAccount)
    }

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

/// Minutes（キーなし）を選択肢に出すか（SPEC §5.6）。公開（製品版の P6）までは、ふつうの利用者には出さない:
/// 価格・利用規約・プライバシーポリシーがそろう前に、アカウントを作る入口を全員に見せない。公開のときにこの決まりを外す。
public enum MinutesCloudOffer {
    /// 公開の前に試す人のための隠しスイッチ: `defaults write jp.pictors.minutes MinutesCloudPreview -bool YES`
    public static let previewDefaultsKey = "MinutesCloudPreview"

    /// 出すのは、この Mac にログインの印がある・すでにキーなしを選んでいる・隠しスイッチが入っている、のどれかのとき。
    /// すでに選んでいる設定は、ログアウトしたあとも選択肢に残す（選択肢から消えると、いまの選択を表示できない）。
    public static func isOffered(hasLogin: Bool, selected: Bool, preview: Bool) -> Bool {
        hasLogin || selected || preview
    }

    public static func isOffered(selected: Bool, defaults: UserDefaults = .standard) -> Bool {
        isOffered(hasLogin: MinutesCloudCredentials.hasStoredLogin, selected: selected, preview: defaults.bool(forKey: previewDefaultsKey))
    }
}
