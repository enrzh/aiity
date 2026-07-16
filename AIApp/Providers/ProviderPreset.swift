import Foundation

/// Wire dialect a provider speaks. Everything that is not Anthropic or
/// on-device MLX goes through the OpenAI chat-completions dialect — the
/// de-facto standard implemented by every hosted and self-hosted gateway.
enum ProviderDialect: String, Codable {
    case openai
    case anthropic
    case mlx
}

enum AuthMode {
    case apiKey
    case oauth
    case none
}

/// One known provider. `oauthAvailable` means a public, self-serve OAuth
/// flow exists that this app implements (currently OpenRouter PKCE);
/// subscription OAuth at OpenAI/Anthropic is partner-gated and therefore
/// not offered as a button.
struct ProviderPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let dialect: ProviderDialect
    let defaultBaseURL: String
    let needsKey: Bool
    let oauthAvailable: Bool
    let editableBaseURL: Bool
    let defaultModel: String

    static let catalog: [ProviderPreset] = [
        ProviderPreset(id: "anthropic", label: "Anthropic (Claude)", dialect: .anthropic,
                       defaultBaseURL: "https://api.anthropic.com", needsKey: true,
                       oauthAvailable: false, editableBaseURL: false, defaultModel: "claude-sonnet-5"),
        ProviderPreset(id: "openai", label: "OpenAI (ChatGPT)", dialect: .openai,
                       defaultBaseURL: "https://api.openai.com/v1", needsKey: true,
                       oauthAvailable: false, editableBaseURL: false, defaultModel: "gpt-5.2"),
        ProviderPreset(id: "openrouter", label: "OpenRouter (alle Modelle)", dialect: .openai,
                       defaultBaseURL: "https://openrouter.ai/api/v1", needsKey: true,
                       oauthAvailable: true, editableBaseURL: false, defaultModel: "anthropic/claude-sonnet-5"),
        ProviderPreset(id: "gemini", label: "Google Gemini", dialect: .openai,
                       defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai", needsKey: true,
                       oauthAvailable: false, editableBaseURL: false, defaultModel: "gemini-2.5-pro"),
        ProviderPreset(id: "mistral", label: "Mistral", dialect: .openai,
                       defaultBaseURL: "https://api.mistral.ai/v1", needsKey: true,
                       oauthAvailable: false, editableBaseURL: false, defaultModel: "mistral-large-latest"),
        ProviderPreset(id: "groq", label: "Groq", dialect: .openai,
                       defaultBaseURL: "https://api.groq.com/openai/v1", needsKey: true,
                       oauthAvailable: false, editableBaseURL: false, defaultModel: "llama-3.3-70b-versatile"),
        ProviderPreset(id: "deepseek", label: "DeepSeek", dialect: .openai,
                       defaultBaseURL: "https://api.deepseek.com/v1", needsKey: true,
                       oauthAvailable: false, editableBaseURL: false, defaultModel: "deepseek-chat"),
        ProviderPreset(id: "xai", label: "xAI (Grok)", dialect: .openai,
                       defaultBaseURL: "https://api.x.ai/v1", needsKey: true,
                       oauthAvailable: false, editableBaseURL: false, defaultModel: "grok-4"),
        ProviderPreset(id: "together", label: "Together AI", dialect: .openai,
                       defaultBaseURL: "https://api.together.xyz/v1", needsKey: true,
                       oauthAvailable: false, editableBaseURL: false, defaultModel: ""),
        ProviderPreset(id: "ollama", label: "Ollama (eigener Rechner)", dialect: .openai,
                       defaultBaseURL: "http://localhost:11434/v1", needsKey: false,
                       oauthAvailable: false, editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "lmstudio", label: "LM Studio (eigener Rechner)", dialect: .openai,
                       defaultBaseURL: "http://localhost:1234/v1", needsKey: false,
                       oauthAvailable: false, editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "localai", label: "LocalAI (self-hosted)", dialect: .openai,
                       defaultBaseURL: "", needsKey: false,
                       oauthAvailable: false, editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "custom-openai", label: "Eigener Server (OpenAI-kompatibel)", dialect: .openai,
                       defaultBaseURL: "", needsKey: false,
                       oauthAvailable: false, editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "custom-anthropic", label: "Eigener Server (Anthropic-kompatibel)", dialect: .anthropic,
                       defaultBaseURL: "", needsKey: false,
                       oauthAvailable: false, editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "mlx", label: "Lokal auf dem Gerät (MLX)", dialect: .mlx,
                       defaultBaseURL: "", needsKey: false,
                       oauthAvailable: false, editableBaseURL: false, defaultModel: ""),
    ]

    static func preset(for id: String) -> ProviderPreset {
        catalog.first(where: { $0.id == id }) ?? catalog[0]
    }
}
