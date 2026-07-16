import Foundation

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case anthropic
    case openAICompatible

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAICompatible: return "OpenAI-kompatibel (OpenAI, OpenRouter, Ollama, LM Studio …)"
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

    static let storageKey = "provider-settings-v1"

    static func load() -> ProviderSettings {
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
        }
    }

    func makeProvider(apiKey: String) -> LLMProvider {
        switch kind {
        case .anthropic:
            return AnthropicProvider(baseURL: effectiveBaseURL, apiKey: apiKey, model: model)
        case .openAICompatible:
            return OpenAICompatibleProvider(baseURL: effectiveBaseURL, apiKey: apiKey, model: model)
        }
    }
}
