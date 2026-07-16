import Foundation

/// Non-secret provider configuration. The API key itself lives in the
/// Keychain (see `Keychain.swift`), never in UserDefaults.
struct ProviderSettings: Codable, Equatable {
    var presetId: String = "anthropic"
    /// Override for presets with editable endpoints (self-hosted, LAN).
    var baseURL: String = ""
    var model: String = ""
    /// Optional search endpoint (SearXNG instance or similar). Empty = use
    /// the built-in DuckDuckGo HTML fallback.
    var searchEndpoint: String = ""
    /// Hub id of the selected on-device model (preset "mlx").
    var localModelId: String = LocalModel.defaultId

    static let storageKey = "provider-settings-v1"

    var preset: ProviderPreset { ProviderPreset.preset(for: presetId) }

    // Manual decoding: every field is optional in stored/injected JSON so
    // settings survive schema growth, and the legacy `kind` field (v1/v2
    // storage and existing test configs) still maps onto a preset.
    private enum CodingKeys: String, CodingKey {
        case presetId, kind, baseURL, model, searchEndpoint, localModelId
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
        localModelId = try values.decodeIfPresent(String.self, forKey: .localModelId) ?? LocalModel.defaultId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(presetId, forKey: .presetId)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(searchEndpoint, forKey: .searchEndpoint)
        try container.encode(localModelId, forKey: .localModelId)
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
              let settings = try? JSONDecoder().decode(ProviderSettings.self, from: data) else {
            return ProviderSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    var effectiveBaseURL: String {
        if !baseURL.isEmpty { return baseURL }
        return preset.defaultBaseURL
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

    var keychainAccount: String { "api-key-\(presetId)" }

    func makeProvider(apiKey: String) -> LLMProvider {
        switch preset.dialect {
        case .anthropic:
            return AnthropicProvider(baseURL: baseURL(forKey: apiKey), apiKey: apiKey, model: effectiveModel)
        case .openai:
            return OpenAICompatibleProvider(baseURL: baseURL(forKey: apiKey), apiKey: apiKey, model: effectiveModel)
        case .mlx:
            return MLXProvider(modelId: localModelId)
        }
    }
}
