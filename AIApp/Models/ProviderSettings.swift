import Foundation

/// Non-secret provider configuration. The API key itself lives in the
/// Keychain (see `Keychain.swift`), never in UserDefaults.
///
/// Chat is one modality slot (`presetId` + `model`). Image and video are
/// independent slots (`imagePresetId`/`imageModel`, `videoPresetId`/`videoModel`)
/// so media is not configured “inside” the chat provider.
struct ProviderSettings: Codable, Equatable {
    /// Active chat provider.
    var presetId: String = "anthropic"
    /// Override for presets with editable endpoints (self-hosted, LAN).
    var baseURL: String = ""
    /// Active chat model.
    var model: String = ""
    /// Optional search endpoint (SearXNG instance or similar). Empty = use
    /// the built-in DuckDuckGo HTML fallback.
    var searchEndpoint: String = ""
    /// Search backend raw value (`SearchBackend`). Default auto cascade.
    var searchBackend: String = SearchBackend.auto.rawValue
    /// Optional Brave Search API key (also mirrored to Keychain as `search-brave-key`).
    var searchBraveKey: String = ""
    /// Optional Tavily API key (also mirrored to Keychain as `search-tavily-key`).
    var searchTavilyKey: String = ""
    /// Hub id of the selected on-device model (preset "mlx").
    var localModelId: String = LocalModel.defaultId

    /// Provider used for `generate_image` (empty = not configured).
    var imagePresetId: String = ""
    var imageModel: String = "gpt-image-1"
    /// Provider used for `generate_video` (empty = not configured).
    var videoPresetId: String = ""
    var videoModel: String = "sora-2"

    static let storageKey = "provider-settings-v1"

    var preset: ProviderPreset { ProviderPreset.preset(for: presetId) }

    // Manual decoding: every field is optional in stored/injected JSON so
    // settings survive schema growth, and the legacy `kind` field (v1/v2
    // storage and existing test configs) still maps onto a preset.
    private enum CodingKeys: String, CodingKey {
        case presetId, kind, baseURL, model, searchEndpoint, localModelId
        case imageModel, videoModel, imagePresetId, videoPresetId
        case searchBackend, searchBraveKey, searchTavilyKey
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let stored = try values.decodeIfPresent(String.self, forKey: .presetId) {
            presetId = stored
        } else if let legacy = try values.decodeIfPresent(String.self, forKey: .kind) {
            switch legacy {
            case "openAICompatible": presetId = "custom-openai"
            case "mlx": presetId = "mlx"
            default: presetId = "anthropic"
            }
        }
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        searchEndpoint = try values.decodeIfPresent(String.self, forKey: .searchEndpoint) ?? ""
        searchBackend = try values.decodeIfPresent(String.self, forKey: .searchBackend) ?? SearchBackend.auto.rawValue
        searchBraveKey = try values.decodeIfPresent(String.self, forKey: .searchBraveKey) ?? ""
        searchTavilyKey = try values.decodeIfPresent(String.self, forKey: .searchTavilyKey) ?? ""
        localModelId = try values.decodeIfPresent(String.self, forKey: .localModelId) ?? LocalModel.defaultId
        imageModel = try values.decodeIfPresent(String.self, forKey: .imageModel) ?? "gpt-image-1"
        videoModel = try values.decodeIfPresent(String.self, forKey: .videoModel) ?? "sora-2"
        imagePresetId = try values.decodeIfPresent(String.self, forKey: .imagePresetId) ?? ""
        videoPresetId = try values.decodeIfPresent(String.self, forKey: .videoPresetId) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(presetId, forKey: .presetId)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(searchEndpoint, forKey: .searchEndpoint)
        try container.encode(searchBackend, forKey: .searchBackend)
        // searchBraveKey / searchTavilyKey are secrets — persisted in the
        // Keychain only, never written to the UserDefaults settings blob.
        try container.encode(localModelId, forKey: .localModelId)
        try container.encode(imageModel, forKey: .imageModel)
        try container.encode(videoModel, forKey: .videoModel)
        try container.encode(imagePresetId, forKey: .imagePresetId)
        try container.encode(videoPresetId, forKey: .videoPresetId)
    }

    static func load() -> ProviderSettings {
        // Plain-JSON override for UI tests and debugging. Passed as an
        // environment variable — launch-argument values go through
        // UserDefaults' plist parsing, which mangles JSON braces.
        if let json = ProcessInfo.processInfo.environment["PROVIDER_SETTINGS_JSON"],
           let settings = try? JSONDecoder().decode(ProviderSettings.self, from: Data(json.utf8)) {
            return settings
        }
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(ProviderSettings.self, from: data) else {
            return ProviderSettings()
        }
        // Search keys are Keychain-backed. Migrate any legacy plaintext value
        // (from older builds that stored it in the settings blob) into the
        // Keychain, then hydrate from there so the field displays but never
        // re-persists to UserDefaults.
        settings.searchBraveKey = Self.hydrateSecret(settings.searchBraveKey, keychainKey: "search-brave-key")
        settings.searchTavilyKey = Self.hydrateSecret(settings.searchTavilyKey, keychainKey: "search-tavily-key")
        return settings
    }

    private static func hydrateSecret(_ decoded: String, keychainKey: String) -> String {
        let stored = Keychain.get(keychainKey)
        if stored.isEmpty && !decoded.isEmpty {
            Keychain.set(decoded, for: keychainKey)  // migrate legacy plaintext
            return decoded
        }
        return stored
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Modality slots

    func activePresetId(for modality: ModelModality) -> String {
        switch modality {
        case .chat: return presetId
        case .image: return imagePresetId
        case .video: return videoPresetId
        }
    }

    func model(for modality: ModelModality) -> String {
        switch modality {
        case .chat: return effectiveModel
        case .image: return imageModel.isEmpty ? ModelModality.image.defaultModel : imageModel
        case .video: return videoModel.isEmpty ? ModelModality.video.defaultModel : videoModel
        }
    }

    mutating func setActivePresetId(_ id: String, for modality: ModelModality) {
        switch modality {
        case .chat: presetId = id
        case .image: imagePresetId = id
        case .video: videoPresetId = id
        }
    }

    mutating func setModel(_ value: String, for modality: ModelModality) {
        switch modality {
        case .chat: model = value
        case .image: imageModel = value
        case .video: videoModel = value
        }
    }

    /// Snapshot of a provider’s connection fields (base URL, dialect) from its
    /// profile — used when image/video run on a different provider than chat.
    static func connectionSnapshot(presetId: String) -> ProviderSettings {
        var s = ProviderSettings()
        let profile = ProviderProfiles.profile(for: presetId)
        s.presetId = presetId
        s.baseURL = profile.baseURL
        s.model = profile.model
        s.localModelId = profile.localModelId.isEmpty ? LocalModel.defaultId : profile.localModelId
        if s.model.isEmpty {
            s.model = ProviderPreset.preset(for: presetId).defaultModel
        }
        return s
    }

    var effectiveBaseURL: String {
        let raw = baseURL.isEmpty ? preset.defaultBaseURL : baseURL
        return ProviderSettings.normalizeBaseURL(raw, dialect: preset.dialect)
    }

    /// Makes a user-typed endpoint forgiving: adds https:// when the scheme is
    /// missing, drops trailing slashes, and appends the OpenAI-compatible
    /// version path when the user pasted only a bare host (so "ki.domain.de"
    /// works for a sub2api / self-hosted gateway).
    static func normalizeBaseURL(_ raw: String, dialect: ProviderDialect) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        // Only the OpenAI dialect wants a "/v1" suffix; Anthropic callers add
        // their own "/v1/messages" path. Leave an already-pathed URL alone.
        if dialect == .openai, let components = URLComponents(string: value),
           components.path.isEmpty {
            value += "/v1"
        }
        return value
    }

    /// Base URL to use for a given credential. OAuth subscription tokens may
    /// need a different endpoint than API keys (Grok's CLI proxy).
    func baseURL(forKey apiKey: String) -> String {
        if apiKey.hasPrefix(AuthStore.oauthMarker), baseURL.isEmpty,
           let override = preset.oauth?.inferenceBaseURL {
            return override
        }
        return effectiveBaseURL
    }

    var effectiveModel: String {
        if !model.isEmpty { return model }
        return preset.defaultModel
    }

    func makeProvider(apiKey: String) -> LLMProvider {
        let isOAuthToken = apiKey.hasPrefix(AuthStore.oauthMarker)
        // A ChatGPT-subscription OAuth token must go through the Codex backend,
        // not the plain chat-completions endpoint.
        if presetId == "openai", isOAuthToken {
            var codexModel = effectiveModel
            if codexModel.isEmpty {
                codexModel = ModelCatalogCache.codexOAuthModels().first?.id ?? "gpt-4.1"
            }
            return OpenAICodexProvider(
                accessToken: String(apiKey.dropFirst(AuthStore.oauthMarker.count)),
                accountId: AuthStore.activeAccountChatGPTId(for: presetId),
                model: codexModel
            )
        }
        switch preset.dialect {
        case .anthropic:
            return AnthropicProvider(baseURL: baseURL(forKey: apiKey), apiKey: apiKey, model: effectiveModel)
        case .openai:
            return OpenAICompatibleProvider(
                baseURL: baseURL(forKey: apiKey),
                apiKey: apiKey,
                model: effectiveModel,
                isLocalRuntime: LocalRuntimePolicy.isLocal(self)
            )
        case .mlx:
            return MLXProvider(modelId: localModelId)
        }
    }
}
