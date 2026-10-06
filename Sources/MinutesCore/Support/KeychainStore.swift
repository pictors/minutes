import Foundation
import Security

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
    }
}

/// API キーの解決順: Keychain → 環境変数 / .env。
public enum APIKeys {
    public static let elevenLabs = ElevenLabsTranscriber.apiKeyEnvName
    public static let openAI = OpenAITranscriber.apiKeyEnvName
    public static let anthropic = ClaudeSummarizer.apiKeyEnvName

    public static func resolve(_ name: String, useKeychain: Bool = true) -> String? {
        if useKeychain, let value = try? KeychainStore.get(account: name), !value.isEmpty { return value }
        return DotEnv.value(for: name)
    }
}
