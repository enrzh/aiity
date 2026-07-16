import Foundation

/// A bearer credential from a standard OAuth flow. Persisted as JSON in the
/// same Keychain slot a manual API key would use — `effectiveKey` hands the
/// providers either the plain key or an "oauth:<token>" marker.
struct OAuthCredential: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
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

    static func clientId(for presetId: String) -> String {
        UserDefaults.standard.string(forKey: "oauth-client-id-\(presetId)") ?? ""
    }

    static func setClientId(_ value: String, for presetId: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "oauth-client-id-\(presetId)")
    }

    /// The value providers receive: a plain API key as-is, an OAuth token as
    /// "oauth:<access token>" — refreshed first when it is about to expire.
    static func effectiveKey(for settings: ProviderSettings) async -> String {
        let account = settings.keychainAccount
        guard var credential = storedOAuthCredential(account: account) else {
            return Keychain.get(account)
        }
        if let expiresAt = credential.expiresAt,
           expiresAt < Date().addingTimeInterval(120),
           let refreshToken = credential.refreshToken,
           let config = settings.preset.oauth, config.flow == .standardPKCE {
            if let refreshed = try? await OAuthService.refresh(
                config: config,
                clientId: clientId(for: settings.presetId),
                refreshToken: refreshToken
            ) {
                credential = refreshed
                save(credential, account: account)
            }
        }
        return oauthMarker + credential.accessToken
    }
}
