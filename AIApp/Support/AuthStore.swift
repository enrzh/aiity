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
        #if DEBUG
        // Hermetic UI tests point a cloud preset at a local stub; this injects a
        // dummy key so the "needs key" gate passes and tools get exercised.
        if let forced = ProcessInfo.processInfo.environment["AIITY_TEST_API_KEY"], !forced.isEmpty {
            return forced
        }
        #endif
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
        guard let credential = storedOAuthCredential(account: key) else {
            return Keychain.get(key)
        }
        // Refresh when expired or about to expire (2 min buffer). Deduped so two
        // near-simultaneous callers (chat stream + model list / connection probe)
        // don't each spend the single-use refresh token — the loser would get
        // `invalid_grant` and could clobber the credential to a stale state.
        if let expiresAt = credential.expiresAt,
           expiresAt < Date().addingTimeInterval(120),
           let refreshToken = credential.refreshToken,
           let config = oauthConfig {
            let refreshed = await TokenRefreshCoordinator.shared.refresh(
                account: key, config: config, refreshToken: refreshToken, currentAccountId: credential.accountId
            )
            if let refreshed { return oauthMarker + refreshed.accessToken }
        }
        return oauthMarker + credential.accessToken
    }
}

/// Serializes OAuth token refresh per account so concurrent callers share one
/// in-flight refresh instead of each burning the single-use refresh token.
actor TokenRefreshCoordinator {
    static let shared = TokenRefreshCoordinator()
    private var inFlight: [String: Task<OAuthCredential?, Never>] = [:]

    #if DEBUG
    /// Test hook: replaces the network refresh so single-flight can be verified.
    nonisolated(unsafe) static var testRefreshOverride: (@Sendable (OAuthProviderConfig, String) async -> OAuthCredential?)?
    #endif

    private nonisolated func performRefresh(config: OAuthProviderConfig, refreshToken: String) async -> OAuthCredential? {
        #if DEBUG
        if let override = Self.testRefreshOverride {
            return await override(config, refreshToken)
        }
        #endif
        return try? await OAuthService.refresh(config: config, refreshToken: refreshToken)
    }

    func refresh(account: String, config: OAuthProviderConfig, refreshToken: String,
                 currentAccountId: String?) async -> OAuthCredential? {
        // A refresh for this account may already have completed while we waited;
        // re-read and skip if the stored credential is now comfortably valid.
        if let current = AuthStore.storedOAuthCredential(account: account),
           let expiresAt = current.expiresAt, expiresAt > Date().addingTimeInterval(120) {
            return current
        }
        if let existing = inFlight[account] {
            return await existing.value
        }
        let task = Task<OAuthCredential?, Never> { [self] in
            guard let refreshed = await performRefresh(config: config, refreshToken: refreshToken) else {
                return nil
            }
            var updated = refreshed
            updated.accountId = updated.accountId ?? currentAccountId
            AuthStore.save(updated, account: account)
            return updated
        }
        inFlight[account] = task
        let result = await task.value
        inFlight[account] = nil
        return result
    }
}
