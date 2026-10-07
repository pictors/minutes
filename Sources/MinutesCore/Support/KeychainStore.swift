import Foundation
import Security
import Synchronization

/// API キーの保管（SPEC §14: API キーは Keychain）。service = jp.pictors.minutes、account = キー名。
public enum KeychainStore {
    public static let service = "jp.pictors.minutes"

    public enum KeychainError: Error, LocalizedError {
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case let .status(status):
                return "Keychain エラー (\(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
            }
        }
    }

    public static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
        APIKeys.forget(account)
    }

    /// 項目があるか。中身は読まないので、読む許可の確認（ダイアログ）を出さない（画面の「保存済み」の表示用）。
    public static func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    public static func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
        APIKeys.forget(account)
    }
}

/// API キーの解決順: Keychain → 環境変数 / .env。
public enum APIKeys {
    public static let elevenLabs = ElevenLabsTranscriber.apiKeyEnvName
    public static let openAI = OpenAITranscriber.apiKeyEnvName
    public static let anthropic = ClaudeSummarizer.apiKeyEnvName

    /// 起動中に Keychain から読んだキー（読めなかったときの nil も含む）。Keychain の読み取りは、許可のない版
    /// （署名の違う版で保存したキーなど）では確認のダイアログを出すので、1 つのキーは 1 回だけ読む（2026-10-07）。
    private static let cache = Mutex<[String: String?]>([:])

    public static func resolve(_ name: String, useKeychain: Bool = true) -> String? {
        if useKeychain, let value = keychainValue(name) { return value }
        return DotEnv.value(for: name)
    }

    /// 同時に読みに来ても Keychain に問い合わせるのは 1 回（確認のダイアログを重ねて出さない）。
    static func keychainValue(_ name: String) -> String? {
        cache.withLock { cache in
            if let cached = cache[name] { return cached }
            let value = (try? KeychainStore.get(account: name)).flatMap { $0.isEmpty ? nil : $0 }
            cache.updateValue(value, forKey: name)
            return value
        }
    }

    /// 保存・削除したキーは次に読むときに読み直す。
    static func forget(_ name: String) {
        _ = cache.withLock { $0.removeValue(forKey: name) }
    }
}
