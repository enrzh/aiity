import Foundation

/// One saved credential for a provider. Multiple accounts per provider are
/// allowed (e.g. two ChatGPT logins, a work + private Claude); the user picks
/// which is active. Non-secret metadata lives in UserDefaults; the secret
/// (API key or OAuth-credential JSON) lives in the Keychain at "account-<id>".
struct Account: Codable, Identifiable, Equatable {
    var id = UUID()
    var presetId: String
    var label: String
    var isOAuth: Bool

    var keychainKey: String { "account-\(id.uuidString)" }
}

/// File/UserDefaults-backed account registry. Static helpers let non-UI code
/// (AuthStore) resolve the active account without holding the ObservableObject.
@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []

    private static let listKey = "accounts-v1"

    init() {
        migrateLegacyIfNeeded()
        accounts = Self.loadAll()
    }

    func accounts(for presetId: String) -> [Account] {
        accounts.filter { $0.presetId == presetId }
    }

    func activeAccount(for presetId: String) -> Account? {
        Self.activeAccount(for: presetId, in: accounts)
    }

    func addKeyAccount(presetId: String, label: String, key: String) {
        let account = Account(presetId: presetId, label: label.isEmpty ? "API-Key" : label, isOAuth: false)
        Keychain.set(key, for: account.keychainKey)
        appendAndActivate(account)
    }

    func addOAuthAccount(presetId: String, label: String, credential: OAuthCredential) {
        let account = Account(presetId: presetId, label: label.isEmpty ? "OAuth" : label, isOAuth: true)
        AuthStore.save(credential, account: account.keychainKey)
        appendAndActivate(account)
    }

    func setActive(_ account: Account) {
        Self.setActiveId(account.id, for: account.presetId)
        objectWillChange.send()
    }

    func delete(_ account: Account) {
        Keychain.set("", for: account.keychainKey)
        accounts.removeAll { $0.id == account.id }
        Self.persist(accounts)
        if Self.activeId(for: account.presetId) == account.id {
            if let next = accounts.first(where: { $0.presetId == account.presetId }) {
                Self.setActiveId(next.id, for: account.presetId)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeKey(account.presetId))
            }
        }
    }

    private func appendAndActivate(_ account: Account) {
        accounts.append(account)
        Self.persist(accounts)
        Self.setActiveId(account.id, for: account.presetId)
    }

    // MARK: - Static resolution (used by AuthStore, off the main actor)

    nonisolated static func loadAll() -> [Account] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let list = try? JSONDecoder().decode([Account].self, from: data) else { return [] }
        return list
    }

    nonisolated static func activeAccount(for presetId: String) -> Account? {
        activeAccount(for: presetId, in: loadAll())
    }

    nonisolated static func activeAccount(for presetId: String, in all: [Account]) -> Account? {
        let candidates = all.filter { $0.presetId == presetId }
        if let id = activeId(for: presetId), let match = candidates.first(where: { $0.id == id }) {
            return match
        }
        return candidates.first
    }

    nonisolated private static func persist(_ list: [Account]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
    }

    nonisolated private static func activeKey(_ presetId: String) -> String { "active-account-\(presetId)" }

    nonisolated private static func activeId(for presetId: String) -> UUID? {
        UserDefaults.standard.string(forKey: activeKey(presetId)).flatMap(UUID.init(uuidString:))
    }

    nonisolated private static func setActiveId(_ id: UUID, for presetId: String) {
        UserDefaults.standard.set(id.uuidString, forKey: activeKey(presetId))
    }

    /// Moves a v3 single-credential (Keychain "api-key-<presetId>") into a
    /// first account so existing logins survive the multi-account upgrade.
    private func migrateLegacyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "accounts-migrated-v1") else { return }
        var migrated = Self.loadAll()
        for preset in ProviderPreset.catalog where ![.mlx, .foundation].contains(preset.dialect) {
            let legacyKey = "api-key-\(preset.id)"
            let raw = Keychain.get(legacyKey)
            guard !raw.isEmpty else { continue }
            let isOAuth = raw.hasPrefix("{")
            let account = Account(presetId: preset.id, label: isOAuth ? "OAuth" : "API-Key", isOAuth: isOAuth)
            Keychain.set(raw, for: account.keychainKey)
            Keychain.set("", for: legacyKey)
            migrated.append(account)
            Self.setActiveId(account.id, for: preset.id)
        }
        Self.persist(migrated)
        UserDefaults.standard.set(true, forKey: "accounts-migrated-v1")
    }
}
