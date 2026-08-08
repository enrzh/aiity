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
        // Profiles have no live-observing owner (they're read on demand via
        // `profile(for:)`, never cached), so the handler is a no-op: if
        // iCloud already has profiles and this device has none yet, pull
        // them in before `ProviderProfiles.profile(for:)` below reads. Later
        // remote changes go through the per-provider merge instead of
        // whole-map overwrite, so a device that never configured a provider
        // cannot erase another device's model pick for it.
        CloudSettingsSync.adopt(
            key: ProviderProfiles.storageKey,
            merge: ProviderProfiles.mergedData
        ) { _ in }

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
        // Local snapshot only, no iCloud push: on a fresh install this is
        // the near-empty default map, and pushing it here raced the KVS
        // initial sync — a reinstall could publish "nothing configured" over
        // the map another device had already built. Real user-driven changes
        // (the `didSet` above, provider screens) still push.
        ProviderProfiles.capture(from: settings, push: false)

        // `settings` above may have loaded the plain local default (a fresh
        // install has nothing in UserDefaults yet) — this call both adopts an
        // existing iCloud value synchronously right here (correcting
        // `settings` before init ever returns, so no observer sees the wrong
        // value) and keeps listening so a later change pushed from another
        // device takes effect without a relaunch. Re-running init (SwiftUI
        // recreating the @StateObject) re-binds the handler to THIS instance;
        // the old one is dropped by CloudSettingsSync's registry.
        CloudSettingsSync.adopt(
            key: ProviderSettings.storageKey,
            merge: ProviderSettings.mergedData
        ) { [weak self] _ in
            self?.settings = ProviderSettings.load()
        }
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
