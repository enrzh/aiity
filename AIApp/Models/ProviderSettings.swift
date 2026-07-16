import Foundation

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case anthropic
    case openAICompatible
    case mlx

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAICompatible: return "OpenAI-kompatibel (OpenAI, OpenRouter, Ollama, LM Studio …)"
        case .mlx: return "Lokal auf dem Gerät (MLX)"
        }
    }
}

/// Non-secret provider configuration. The API key itself lives in the
/// Keychain (see `Keychain.swift`), never in UserDefaults.
struct ProviderSettings: Codable, Equatable {
    var kind: ProviderKind = .anthropic
    var baseURL: String = ""
    var model: String = "claude-sonnet-5"
    /// Optional search endpoint (SearXNG instance or similar). Empty = use
    /// the built-in DuckDuckGo HTML fallback.
    var searchEndpoint: String = ""
    /// Hub id of the selected on-device model (kind == .mlx).
    var localModelId: String = LocalModel.defaultId

    static let storageKey = "provider-settings-v1"

    // Manual decoding: every field is optional in stored/injected JSON so
    // settings survive schema growth (and tests can pass partial configs).
    private enum CodingKeys: String, CodingKey {
        case kind, baseURL, model, searchEndpoint, localModelId
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(ProviderKind.self, forKey: .kind) ?? .anthropic
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? "claude-sonnet-5"
        searchEndpoint = try values.decodeIfPresent(String.self, forKey: .searchEndpoint) ?? ""
        localModelId = try values.decodeIfPresent(String.self, forKey: .localModelId) ?? LocalModel.defaultId
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
        switch kind {
        case .anthropic: return "https://api.anthropic.com"
        case .openAICompatible: return "https://api.openai.com/v1"
        case .mlx: return ""
        }
    }

    func makeProvider(apiKey: String) -> LLMProvider {
        switch kind {
        case .anthropic:
            return AnthropicProvider(baseURL: effectiveBaseURL, apiKey: apiKey, model: model)
        case .openAICompatible:
            return OpenAICompatibleProvider(baseURL: effectiveBaseURL, apiKey: apiKey, model: model)
        case .mlx:
            return MLXProvider(modelId: localModelId)
        }
    }
}
