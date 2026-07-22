import Foundation

/// A bearer credential from a standard OAuth flow. Persisted as JSON in the
/// Keychain slot of its account — `effectiveKey` hands the providers either
/// the plain key or an "oauth:<token>" marker. `accountId` carries OpenAI's
/// chatgpt_account_id (from the id_token) for the Codex responses backend.
struct OAuthCredential: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var accountId: String?
}

enum AuthStore {
    static let oauthMarker = "oauth:"

    static func storedOAuthCredential(account: String) -> OAuthCredential? {
        let raw = Keychain.get(account)
        guard raw.hasPrefix("{"),
              let credential = try? JSONDecoder().decode(OAuthCredential.self, from: Data(raw.utf8)) else {
            return nil
        }
        return credential
    }

    static func save(_ credential: OAuthCredential, account: String) {
        if let data = try? JSONEncoder().encode(credential) {
            Keychain.set(String(decoding: data, as: UTF8.self), for: account)
        }
    }

    static func isOAuthConnected(account: String) -> Bool {
        storedOAuthCredential(account: account) != nil
    }

    /// Resolved secret for the provider's ACTIVE account: a plain API key
    /// as-is, or an OAuth token as "oauth:<access token>" (refreshed first
    /// when near expiry). Empty when no account is configured.
    static func effectiveKey(for settings: ProviderSettings) async -> String {
        guard let account = AccountStore.activeAccount(for: settings.presetId) else { return "" }
        return await effectiveKey(forKeychainKey: account.keychainKey, oauthConfig: settings.preset.oauth)
    }

    /// The OpenAI chatgpt_account_id of the active account, if it is an OAuth
    /// login (needed for the Codex responses header).
    static func activeAccountChatGPTId(for presetId: String) -> String? {
        guard let account = AccountStore.activeAccount(for: presetId) else { return nil }
        return storedOAuthCredential(account: account.keychainKey)?.accountId
    }

    private static func effectiveKey(forKeychainKey key: String, oauthConfig: OAuthProviderConfig?) async -> String {
        guard var credential = storedOAuthCredential(account: key) else {
            return Keychain.get(key)
        }
        // Refresh when expired or about to expire (2 min buffer).
        if let expiresAt = credential.expiresAt,
           expiresAt < Date().addingTimeInterval(120),
           let refreshToken = credential.refreshToken,
           let config = oauthConfig {
            if let refreshed = try? await OAuthService.refresh(config: config, refreshToken: refreshToken) {
                var updated = refreshed
                updated.accountId = updated.accountId ?? credential.accountId
                credential = updated
                save(credential, account: key)
            }
        }
        return oauthMarker + credential.accessToken
    }
}
