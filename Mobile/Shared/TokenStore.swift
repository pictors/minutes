import Foundation
import MinutesKit
import Security

/// ログインの印（Bearer）と、ログイン中の利用者（表示用）を Keychain に置く（製品版の P4）。
/// 印とメールアドレスはログに出さない。iPhone と Watch はそれぞれの Keychain に置く（Watch には iPhone から渡す）。
final class TokenStore: @unchecked Sendable {
    static let shared = TokenStore()

    /// Mac（MinutesCloudCredentials）と同じ名前
    static let service = "jp.pictors.minutes"
    static let tokenAccount = "minutes-cloud-session"
    static let userAccount = "minutes-cloud-user"

    /// どの方法でログインしたか（アカウントの削除で Apple の取り消しを頼むかに使う）
    enum Method: String, Codable, Sendable {
        case apple
        case email
        /// パスキー（iPhone）
        case passkey
        /// iPhone から受け取った（Watch）
        case phone
    }

    struct Stored: Codable, Sendable, Equatable {
        var user: MinutesCloudUser?
        var method: Method
    }

    private let lock = NSLock()
    private var loaded = false
    private var cachedToken: String?
    private var cachedStored: Stored?

    /// 開発のビルド（DEBUG）だけ: 手元のサーバーの印を環境変数で渡せる（Mac の CLI の MINUTES_CLOUD_TOKEN と同じ。シミュレータでは SIMCTL_CHILD_ を付ける）
    static let tokenEnvName = "MINUTES_CLOUD_TOKEN"

    func token() -> String? {
        #if DEBUG
        if let token = ProcessInfo.processInfo.environment[Self.tokenEnvName], !token.isEmpty { return token }
        #endif
        return lock.withLock {
            loadIfNeeded()
            return cachedToken
        }
    }

    var stored: Stored? {
        lock.withLock {
            loadIfNeeded()
            return cachedStored
        }
    }

    var isSignedIn: Bool { token() != nil }

    func save(token: String, user: MinutesCloudUser?, method: Method) throws {
        let stored = Stored(user: user, method: method)
        try lock.withLock {
            try Self.write(Data(token.utf8), account: Self.tokenAccount)
            try Self.write(try JSONEncoder().encode(stored), account: Self.userAccount)
            cachedToken = token
            cachedStored = stored
            loaded = true
        }
    }

    func update(user: MinutesCloudUser) {
        lock.withLock {
            loadIfNeeded()
            guard var stored = cachedStored, stored.user != user else { return }
            stored.user = user
            if let data = try? JSONEncoder().encode(stored), (try? Self.write(data, account: Self.userAccount)) != nil {
                cachedStored = stored
            }
        }
    }

    func clear() {
        lock.withLock {
            Self.delete(account: Self.tokenAccount)
            Self.delete(account: Self.userAccount)
            cachedToken = nil
            cachedStored = nil
            loaded = true
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        cachedToken = Self.read(account: Self.tokenAccount).map { String(decoding: $0, as: UTF8.self) }
        cachedStored = Self.read(account: Self.userAccount).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        loaded = true
    }

    // MARK: Keychain

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read(account: String) -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, account: String) throws {
        let query = query(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            // 裏の送信（画面のロック中）でも読めるように、最初のロック解除のあとは読めるようにする
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw TokenStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw TokenStoreError.keychain(status)
        }
    }

    private static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

enum TokenStoreError: Error, LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychain(status): "ログインの情報を保存できませんでした（Keychain \(status)）"
        }
    }
}
