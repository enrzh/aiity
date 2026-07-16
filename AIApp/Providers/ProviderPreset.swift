import Foundation

/// Wire dialect a provider speaks. Everything that is not Anthropic or
/// on-device MLX goes through the OpenAI chat-completions dialect — the
/// de-facto standard implemented by every hosted and self-hosted gateway.
enum ProviderDialect: String, Codable {
    case openai
    case anthropic
    case mlx
}

/// OAuth description of a provider that actually offers a flow.
/// `standardPKCE` is OAuth 2.0 authorization-code + PKCE returning bearer
/// tokens (with refresh); `openRouterKeyExchange` is OpenRouter's variant
/// where the code exchange mints a plain API key.
struct OAuthProviderConfig: Equatable {
    enum Flow { case standardPKCE, openRouterKeyExchange }
    let flow: Flow
    let authorizeURL: String
    let tokenURL: String
    let scopes: String
    /// True when the provider issues per-app client ids (developer must
    /// register the app once and paste the id in settings).
    let needsClientId: Bool
    let callback: String
}

/// One known provider.
struct ProviderPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let dialect: ProviderDialect
    let defaultBaseURL: String
    let needsKey: Bool
    let editableBaseURL: Bool
    let defaultModel: String
    let oauth: OAuthProviderConfig?

    init(id: String, label: String, dialect: ProviderDialect, defaultBaseURL: String,
         needsKey: Bool, editableBaseURL: Bool, defaultModel: String,
         oauth: OAuthProviderConfig? = nil) {
        self.id = id
        self.label = label
        self.dialect = dialect
        self.defaultBaseURL = defaultBaseURL
        self.needsKey = needsKey
        self.editableBaseURL = editableBaseURL
        self.defaultModel = defaultModel
        self.oauth = oauth
    }

    var oauthAvailable: Bool { oauth != nil }

    static let catalog: [ProviderPreset] = [
        ProviderPreset(id: "anthropic", label: "Anthropic (Claude)", dialect: .anthropic,
                       defaultBaseURL: "https://api.anthropic.com", needsKey: true,
                       editableBaseURL: false, defaultModel: "claude-sonnet-5",
                       oauth: OAuthProviderConfig(
                           flow: .standardPKCE,
                           authorizeURL: "https://claude.ai/oauth/authorize",
                           tokenURL: "https://console.anthropic.com/v1/oauth/token",
                           scopes: "user:inference user:profile",
                           needsClientId: true,
                           callback: "aiapp://oauth/anthropic"
                       )),
        ProviderPreset(id: "openai", label: "OpenAI (ChatGPT)", dialect: .openai,
                       defaultBaseURL: "https://api.openai.com/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "gpt-5.2"),
        ProviderPreset(id: "openrouter", label: "OpenRouter (alle Modelle)", dialect: .openai,
                       defaultBaseURL: "https://openrouter.ai/api/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "anthropic/claude-sonnet-5",
                       oauth: OAuthProviderConfig(
                           flow: .openRouterKeyExchange,
                           authorizeURL: "https://openrouter.ai/auth",
                           tokenURL: "https://openrouter.ai/api/v1/auth/keys",
                           scopes: "",
                           needsClientId: false,
                           callback: "aiapp://oauth/openrouter"
                       )),
        ProviderPreset(id: "gemini", label: "Google Gemini", dialect: .openai,
                       defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai", needsKey: true,
                       editableBaseURL: false, defaultModel: "gemini-2.5-pro"),
        ProviderPreset(id: "mistral", label: "Mistral", dialect: .openai,
                       defaultBaseURL: "https://api.mistral.ai/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "mistral-large-latest"),
        ProviderPreset(id: "groq", label: "Groq", dialect: .openai,
                       defaultBaseURL: "https://api.groq.com/openai/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "llama-3.3-70b-versatile"),
        ProviderPreset(id: "deepseek", label: "DeepSeek", dialect: .openai,
                       defaultBaseURL: "https://api.deepseek.com/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "deepseek-chat"),
        ProviderPreset(id: "xai", label: "xAI (Grok)", dialect: .openai,
                       defaultBaseURL: "https://api.x.ai/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "grok-4"),
        ProviderPreset(id: "together", label: "Together AI", dialect: .openai,
                       defaultBaseURL: "https://api.together.xyz/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: ""),
        ProviderPreset(id: "ollama", label: "Ollama (eigener Rechner)", dialect: .openai,
                       defaultBaseURL: "http://localhost:11434/v1", needsKey: false,
                       editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "lmstudio", label: "LM Studio (eigener Rechner)", dialect: .openai,
                       defaultBaseURL: "http://localhost:1234/v1", needsKey: false,
                       editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "localai", label: "LocalAI (self-hosted)", dialect: .openai,
                       defaultBaseURL: "", needsKey: false,
                       editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "sub2api", label: "sub2api (Abo-Gateway, self-hosted)", dialect: .openai,
                       defaultBaseURL: "", needsKey: false,
                       editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "custom-openai", label: "Eigener Server (OpenAI-kompatibel)", dialect: .openai,
                       defaultBaseURL: "", needsKey: false,
                       editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "custom-anthropic", label: "Eigener Server (Anthropic-kompatibel)", dialect: .anthropic,
                       defaultBaseURL: "", needsKey: false,
                       editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "mlx", label: "Lokal auf dem Gerät (MLX)", dialect: .mlx,
                       defaultBaseURL: "", needsKey: false,
                       editableBaseURL: false, defaultModel: ""),
    ]

    static func preset(for id: String) -> ProviderPreset {
        catalog.first(where: { $0.id == id }) ?? catalog[0]
    }
}
