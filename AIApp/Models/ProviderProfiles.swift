import Foundation

/// Per-provider non-secret fields so switching providers doesn't wipe the
/// model/base URL the user already configured. Image/video models live on the
/// global modality slots in `ProviderSettings`, not nested here.
struct ProviderProfile: Codable, Equatable {
    var baseURL: String = ""
    var model: String = ""
    var localModelId: String = LocalModel.defaultId
    /// Last image model chosen when this provider was the image slot (hint only).
    var lastImageModel: String = ""
    /// Last video model chosen when this provider was the video slot (hint only).
    var lastVideoModel: String = ""

    // Legacy decode keys from when media models lived on the profile.
    private enum CodingKeys: String, CodingKey {
        case baseURL, model, localModelId, lastImageModel, lastVideoModel
        case imageModel, videoModel
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
        lastVideoModel = try c.decodeIfPresent(String.self, forKey: .lastVideoModel)
            ?? c.decodeIfPresent(String.self, forKey: .videoModel)
            ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(model, forKey: .model)
        try c.encode(localModelId, forKey: .localModelId)
        try c.encode(lastImageModel, forKey: .lastImageModel)
        try c.encode(lastVideoModel, forKey: .lastVideoModel)
    }
}

enum ProviderProfiles {
    private static let storageKey = "provider-profiles-v1"

    static func loadAll() -> [String: ProviderProfile] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: ProviderProfile].self, from: data) else {
            return [:]
        }
        return map
    }

    static func saveAll(_ map: [String: ProviderProfile]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    static func profile(for presetId: String) -> ProviderProfile {
        loadAll()[presetId] ?? ProviderProfile()
    }

    static func update(presetId: String, mutate: (inout ProviderProfile) -> Void) {
        var all = loadAll()
        var profile = all[presetId] ?? ProviderProfile()
        mutate(&profile)
        all[presetId] = profile
        saveAll(all)
    }

    /// Snapshot current chat provider fields into that provider's profile.
    static func capture(from settings: ProviderSettings) {
        update(presetId: settings.presetId) { profile in
            profile.baseURL = settings.baseURL
            profile.model = settings.model
            profile.localModelId = settings.localModelId
        }
        // Remember last media models on their slot providers (if set).
        if !settings.imagePresetId.isEmpty {
            update(presetId: settings.imagePresetId) { profile in
                profile.lastImageModel = settings.imageModel
            }
        }
        if !settings.videoPresetId.isEmpty {
            update(presetId: settings.videoPresetId) { profile in
                profile.lastVideoModel = settings.videoModel
            }
        }
    }

    /// Apply a stored profile onto chat settings when switching chat provider.
    /// Does not touch image/video modality slots.
    static func apply(_ profile: ProviderProfile, presetId: String, to settings: inout ProviderSettings) {
        settings.presetId = presetId
        settings.baseURL = profile.baseURL
        settings.model = profile.model
        settings.localModelId = profile.localModelId.isEmpty ? LocalModel.defaultId : profile.localModelId
        if settings.model.isEmpty {
            settings.model = ProviderPreset.preset(for: presetId).defaultModel
        }
    }
}
