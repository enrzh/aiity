import Foundation
import Security

/// Minimal generic-password Keychain wrapper for provider API keys.
enum Keychain {
    /// Current service id (matches bundle id branding).
    private static let service = "com.aiity.app"
    /// Pre-rebrand service — read-migrate so existing installs keep keys.
    private static let legacyService = "de.dongfang.aiapp"

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        // Drop legacy slot if present so we don't leave secrets under the old id.
        delete(account: account, service: legacyService)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ account: String) -> String {
        if let value = read(account: account, service: service), !value.isEmpty {
            return value
        }
        // One-shot migrate from pre-com.aiity installs.
        if let legacy = read(account: account, service: legacyService), !legacy.isEmpty {
            set(legacy, for: account)
            return legacy
        }
        return ""
    }

    private static func read(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func delete(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
