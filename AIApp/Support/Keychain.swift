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
        // ThisDeviceOnly: secrets (API keys, OAuth refresh tokens) must NOT travel
        // in encrypted device backups to another device.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ account: String) -> String {
        if let value = read(account: account, service: service), !value.isEmpty {
            // Items written by older builds still carry AfterFirstUnlock (they
            // travel in device backups). Re-write once so the stricter
            // ThisDeviceOnly attribute actually applies to existing secrets.
            if needsAccessibilityUpgrade(account: account) {
                set(value, for: account)
            }
            return value
        }
        // One-shot migrate from pre-com.aiity installs.
        if let legacy = read(account: account, service: legacyService), !legacy.isEmpty {
            set(legacy, for: account)
            return legacy
        }
        return ""
    }

    /// True when the stored item's accessibility is looser than what `set` writes.
    private static func needsAccessibilityUpgrade(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return false }
        let current = attributes[kSecAttrAccessible as String] as? String
        return current != (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
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
