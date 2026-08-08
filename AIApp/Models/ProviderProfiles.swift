import Foundation

/// Per-provider non-secret fields so switching providers doesn't wipe the
/// model/base URL the user already configured. The image model lives on the
/// global modality slot in `ProviderSettings`, not nested here.
struct ProviderProfile: Codable, Equatable {
    var baseURL: String = ""
    /// The chat model the user explicitly chose for this provider. An empty
    /// string means "the user has not chosen a model" — a deliberate state,
    /// not a gap to fill: nothing (including settings sync/merge, which must
    /// prefer a non-empty value from another device over inventing one here)
    /// may write a default into it silently. Only a genuine user action
    /// commits a model; request-time fallback lives in
    /// `ProviderSettings.effectiveModel` and never persists.
    var model: String = ""
    var localModelId: String = LocalModel.defaultId
    /// Last image model chosen when this provider was the image slot (hint only).
    var lastImageModel: String = ""

    // Legacy decode keys from when media models lived on the profile.
    private enum CodingKeys: String, CodingKey {
        case baseURL, model, localModelId, lastImageModel
        case imageModel
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        localModelId = try c.decodeIfPresent(String.self, forKey: .localModelId) ?? LocalModel.defaultId
        lastImageModel = try c.decodeIfPresent(String.self, forKey: .lastImageModel)
            ?? c.decodeIfPresent(String.self, forKey: .imageModel)
            ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(model, forKey: .model)
        try c.encode(localModelId, forKey: .localModelId)
        try c.encode(lastImageModel, forKey: .lastImageModel)
    }
}

enum ProviderProfiles {
    static let storageKey = "provider-profiles-v1"

    static func loadAll() -> [String: ProviderProfile] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: ProviderProfile].self, from: data) else {
            return [:]
        }
        return map
    }

    /// `push: false` writes only locally. Used for init-time snapshots: a
    /// fresh install capturing its default settings must not push that
    /// near-empty map to iCloud before the KVS initial sync has had a chance
    /// to deliver the map another device already built.
    static func saveAll(_ map: [String: ProviderProfile], push: Bool = true) {
        let encoder = JSONEncoder()
        // Deterministic bytes: a dictionary re-encoded in hash order would
        // look "changed" every time and defeat the identical-blob guards in
        // CloudSettingsSync.
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(map) {
            UserDefaults.standard.set(data, forKey: storageKey)
            if push {
                CloudSettingsSync.push(key: storageKey, data: data)
            }
        }
    }

    static func profile(for presetId: String) -> ProviderProfile {
        loadAll()[presetId] ?? ProviderProfile()
    }

    static func update(presetId: String, push: Bool = true, mutate: (inout ProviderProfile) -> Void) {
        var all = loadAll()
        var profile = all[presetId] ?? ProviderProfile()
        mutate(&profile)
        all[presetId] = profile
        saveAll(all, push: push)
    }

    /// Snapshot current chat provider fields into that provider's profile.
    static func capture(from settings: ProviderSettings, push: Bool = true) {
        update(presetId: settings.presetId, push: push) { profile in
            profile.baseURL = settings.baseURL
            profile.model = settings.model
            profile.localModelId = settings.localModelId
        }
        // Remember the last image model on its slot provider (if set).
        if !settings.imagePresetId.isEmpty {
            update(presetId: settings.imagePresetId, push: push) { profile in
                profile.lastImageModel = settings.imageModel
            }
        }
    }

    // MARK: - KVS merge

    /// Per-provider union merge for the iCloud KVS blob, replacing whole-map
    /// last-writer-wins. Rules per presetId:
    /// - present on only one side → kept (a device that never configured a
    ///   provider must not delete another device's knowledge of it);
    /// - present on both → the incoming entry wins field by field, EXCEPT
    ///   that an empty incoming field never clobbers a non-empty local one.
    ///   For `model` that is the documented contract: empty means "the user
    ///   has not chosen" — adopting another device's explicit pick is the
    ///   point of sync, but an empty remote value must not erase a local
    ///   pick, and two empties stay empty (nothing invents a default).
    static func merged(
        local: [String: ProviderProfile],
        incoming: [String: ProviderProfile]
    ) -> [String: ProviderProfile] {
        var result = local
        for (presetId, remote) in incoming {
            guard let mine = result[presetId] else {
                result[presetId] = remote
                continue
            }
            var resolved = remote
            if resolved.model.isEmpty { resolved.model = mine.model }
            if resolved.baseURL.isEmpty { resolved.baseURL = mine.baseURL }
            if resolved.localModelId.isEmpty { resolved.localModelId = mine.localModelId }
            if resolved.lastImageModel.isEmpty { resolved.lastImageModel = mine.lastImageModel }
            result[presetId] = resolved
        }
        return result
    }

    /// `CloudSettingsSync.Merge` adapter. Falls back to the incoming blob when
    /// either side fails to decode — same outcome the old overwrite had.
    static func mergedData(local: Data, incoming: Data) -> Data {
        let decoder = JSONDecoder()
        guard let mine = try? decoder.decode([String: ProviderProfile].self, from: local),
              let remote = try? decoder.decode([String: ProviderProfile].self, from: incoming) else {
            return incoming
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(merged(local: mine, incoming: remote))) ?? incoming
    }

    /// Apply a stored profile onto chat settings when switching chat provider.
    /// Does not touch the image modality slot.
    ///
    /// Deliberately does NOT fill `preset.defaultModel` when the profile has no
    /// model: an empty model is the visible "user has not chosen yet" state
    /// (the provider list shows "Kein Modell", leaving the provider screen
    /// asks). Requests still work for presets with a default via the
    /// transient `ProviderSettings.effectiveModel` fallback.
    static func apply(_ profile: ProviderProfile, presetId: String, to settings: inout ProviderSettings) {
        settings.presetId = presetId
        settings.baseURL = profile.baseURL
        settings.model = profile.model
        settings.localModelId = profile.localModelId.isEmpty ? LocalModel.defaultId : profile.localModelId
    }
}
