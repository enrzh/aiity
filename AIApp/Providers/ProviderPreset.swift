import Foundation

/// Wire dialect a provider speaks. Everything that is not Anthropic or
/// on-device MLX goes through the OpenAI chat-completions dialect — the
/// de-facto standard implemented by every hosted and self-hosted gateway.
enum ProviderDialect: String, Codable {
    case openai
    case anthropic
    case mlx
}

/// OAuth flow shape. Ported from the sub2api gateway:
/// - `openRouterKeyExchange`: browser redirect (custom scheme) -> code mints
///   a plain API key.
/// - `pasteCode`: the CLI subscription flow used by Codex CLI / Claude Code /
///   grok-cli. The provider redirects to a localhost or hosted callback that
///   shows an authorization code; the user copies it back into the app, which
///   runs the PKCE token exchange. This is how a personal ChatGPT / Claude /
///   Grok subscription authenticates a first-party CLI client.
struct OAuthProviderConfig: Equatable {
    enum Flow { case pasteCode, openRouterKeyExchange }
    enum TokenBody { case json, form }

    let flow: Flow
    let clientId: String
    let authorizeURL: String
    let tokenURL: String
    let redirectURI: String
    let scope: String
    let tokenBody: TokenBody
    let usesNonce: Bool
    /// Extra authorize-URL params (Codex simplified flow, xAI plan, …).
    let extraAuthParams: [String: String]
    /// Base URL to talk to once authenticated with the OAuth token, when it
    /// differs from the API-key base URL (Grok's CLI proxy).
    let inferenceBaseURL: String?

    init(flow: Flow, clientId: String, authorizeURL: String, tokenURL: String,
         redirectURI: String, scope: String, tokenBody: TokenBody = .form,
         usesNonce: Bool = false, extraAuthParams: [String: String] = [:],
         inferenceBaseURL: String? = nil) {
        self.flow = flow
        self.clientId = clientId
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.redirectURI = redirectURI
        self.scope = scope
        self.tokenBody = tokenBody
        self.usesNonce = usesNonce
        self.extraAuthParams = extraAuthParams
        self.inferenceBaseURL = inferenceBaseURL
    }
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
                           flow: .pasteCode,
                           clientId: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                           authorizeURL: "https://claude.ai/oauth/authorize",
                           tokenURL: "https://platform.claude.com/v1/oauth/token",
                           redirectURI: "https://platform.claude.com/oauth/code/callback",
                           scope: "org:create_api_key user:profile user:inference",
                           tokenBody: .json,
                           extraAuthParams: ["code": "true"]
                       )),
        // OpenAI deliberately has NO in-app OAuth: a ChatGPT-subscription
        // token only works through chatgpt.com's private Codex responses
        // backend, which requires fully impersonating the official Codex CLI
        // (user-agent, originator, mandatory Codex system prompt) and can't
        // be verified here. For subscription inference, route through the
        // user's own sub2api gateway (which does exactly that, server-side),
        // or use an API key / OpenRouter.
        ProviderPreset(id: "openai", label: "OpenAI (ChatGPT)", dialect: .openai,
                       defaultBaseURL: "https://api.openai.com/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "gpt-5.2"),
        ProviderPreset(id: "openrouter", label: "OpenRouter (alle Modelle)", dialect: .openai,
                       defaultBaseURL: "https://openrouter.ai/api/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "anthropic/claude-sonnet-5",
                       oauth: OAuthProviderConfig(
                           flow: .openRouterKeyExchange,
                           clientId: "",
                           authorizeURL: "https://openrouter.ai/auth",
                           tokenURL: "https://openrouter.ai/api/v1/auth/keys",
                           redirectURI: "aiapp://oauth/openrouter",
                           scope: ""
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
                       editableBaseURL: false, defaultModel: "grok-4",
                       oauth: OAuthProviderConfig(
                           flow: .pasteCode,
                           clientId: "b1a00492-073a-47ea-816f-4c329264a828",
                           authorizeURL: "https://auth.x.ai/oauth2/authorize",
                           tokenURL: "https://auth.x.ai/oauth2/token",
                           redirectURI: "http://127.0.0.1:56121/callback",
                           scope: "openid profile email offline_access grok-cli:access api:access",
                           tokenBody: .form,
                           usesNonce: true,
                           extraAuthParams: ["plan": "generic"],
                           inferenceBaseURL: "https://cli-chat-proxy.grok.com/v1"
                       )),
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
