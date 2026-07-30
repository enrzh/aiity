import SwiftUI

/// Shared, observable wrapper around provider settings. Chat and image each
/// have an independent active provider; per-provider baseURL/model history
/// lives in `ProviderProfiles`.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: ProviderSettings {
        didSet {
            settings.save()
            ProviderProfiles.capture(from: settings)
        }
    }

    init() {
        var loaded = ProviderSettings.load()
        // Hydrate chat fields from per-provider profile if present.
        let profile = ProviderProfiles.profile(for: loaded.presetId)
        if loaded.model.isEmpty && !profile.model.isEmpty {
            loaded.model = profile.model
        }
        if loaded.baseURL.isEmpty && !profile.baseURL.isEmpty {
            loaded.baseURL = profile.baseURL
        }
        settings = loaded
        ProviderProfiles.capture(from: settings)
    }

    /// Switch which provider the chat talks to, restoring that provider's last
    /// model/base URL. The image slot stays as it is.
    func useForChat(_ presetId: String) {
        guard settings.presetId != presetId else { return }
        ProviderProfiles.capture(from: settings)
        var updated = settings
        let profile = ProviderProfiles.profile(for: presetId)
        ProviderProfiles.apply(profile, presetId: presetId, to: &updated)
        settings = updated
        Analytics.track("provider_switch", ["to": presetId, "modality": "chat"])
    }

    /// Assign a provider as the image-generation slot (and optional model).
    func useForImage(_ presetId: String, model: String? = nil) {
        let previous = settings.imagePresetId
        var updated = settings
        updated.imagePresetId = presetId
        if let model, !model.isEmpty {
            updated.imageModel = model
        } else if updated.imageModel.isEmpty || previous != presetId {
            let hint = ProviderProfiles.profile(for: presetId).lastImageModel
            updated.imageModel = hint.isEmpty ? ModelModality.image.defaultModel : hint
        }
        settings = updated
        Analytics.track("provider_switch", ["to": presetId, "modality": "image"])
    }

    func use(for modality: ModelModality, presetId: String, model: String? = nil) {
        switch modality {
        case .chat: useForChat(presetId)
        case .image: useForImage(presetId, model: model)
        }
    }

    func isActive(presetId: String, for modality: ModelModality) -> Bool {
        settings.activePresetId(for: modality) == presetId
    }
}
