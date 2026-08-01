import Foundation

/// Wire dialect a provider speaks. Everything that is not Anthropic or
/// on-device MLX goes through the OpenAI chat-completions dialect — the
/// de-facto standard implemented by every hosted and self-hosted gateway.
enum ProviderDialect: String, Codable {
    case openai
    case anthropic
    case mlx
}

/// OAuth flow shape. Two are supported, both of which mint a credential aiity
/// can use as an ordinary client:
/// - `openRouterKeyExchange`: browser redirect (custom scheme) -> code mints
///   a plain API key.
/// - `pasteCode`: the provider redirects to a hosted callback showing an
///   authorization code; the user copies it back into the app, which runs the
///   PKCE token exchange. Used by the Claude subscription login.
///
/// Subscription logins whose tokens only work against a first-party backend
/// that checks for its own CLI (ChatGPT/Codex, Grok) are deliberately absent —
/// reaching them requires impersonating that CLI, which aiity does not do.
/// Those providers are API-key only.
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
    /// Extra authorize-URL params (Claude asks for `code=true`).
    let extraAuthParams: [String: String]
    /// Send `state` in the token-exchange body. Standard OAuth does NOT (state
    /// is only the authorize/callback CSRF check) — only Claude's flow echoes
    /// code#state and wants it back.
    let stateInTokenExchange: Bool

    init(flow: Flow, clientId: String, authorizeURL: String, tokenURL: String,
         redirectURI: String, scope: String, tokenBody: TokenBody = .form,
         extraAuthParams: [String: String] = [:], stateInTokenExchange: Bool = false) {
        self.flow = flow
        self.clientId = clientId
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.redirectURI = redirectURI
        self.scope = scope
        self.tokenBody = tokenBody
        self.extraAuthParams = extraAuthParams
        self.stateInTokenExchange = stateInTokenExchange
    }
}

/// How much we actually know about a provider working end to end.
///
/// Everything here runs on the same two wire dialects, so an untested entry is
/// very likely fine — but "likely fine" and "we ran a chat through it" are not
/// the same claim, and the picker shouldn't present them as equal.
enum ProviderMaturity {
    /// A real request has been run through this provider from the app.
    case verified
    /// Same code path, never exercised by us. Offered, but labelled honestly.
    case untested
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
    let maturity: ProviderMaturity

    init(id: String, label: String, dialect: ProviderDialect, defaultBaseURL: String,
         needsKey: Bool, editableBaseURL: Bool, defaultModel: String,
         oauth: OAuthProviderConfig? = nil, maturity: ProviderMaturity = .untested) {
        self.id = id
        self.label = label
        self.dialect = dialect
        self.defaultBaseURL = defaultBaseURL
        self.needsKey = needsKey
        self.editableBaseURL = editableBaseURL
        self.defaultModel = defaultModel
        self.oauth = oauth
        self.maturity = maturity
    }

    var oauthAvailable: Bool { oauth != nil }
    var isVerified: Bool { maturity == .verified }

    static func catalog(maturity: ProviderMaturity) -> [ProviderPreset] {
        catalog.filter { $0.maturity == maturity }
    }

    static let catalog: [ProviderPreset] = [
        ProviderPreset(id: "anthropic", label: "Anthropic (Claude)", dialect: .anthropic,
                       defaultBaseURL: "https://api.anthropic.com", needsKey: true,
                       editableBaseURL: false, defaultModel: "claude-sonnet-4-5",
                       oauth: OAuthProviderConfig(
                           flow: .pasteCode,
                           clientId: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                           authorizeURL: "https://claude.ai/oauth/authorize",
                           tokenURL: "https://platform.claude.com/v1/oauth/token",
                           redirectURI: "https://platform.claude.com/oauth/code/callback",
                           scope: "org:create_api_key user:profile user:inference",
                           tokenBody: .json,
                           extraAuthParams: ["code": "true"],
                           stateInTokenExchange: true
                       )),
        // API-key only. A ChatGPT-subscription token is accepted solely by the
        // Codex backend, which serves the Codex CLI — reaching it means posing
        // as that CLI, so aiity doesn't offer the subscription login at all.
        ProviderPreset(id: "openai", label: "OpenAI (ChatGPT)", dialect: .openai,
                       defaultBaseURL: "https://api.openai.com/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "gpt-4.1"),
        ProviderPreset(id: "openrouter", label: "OpenRouter (alle Modelle)", dialect: .openai,
                       defaultBaseURL: "https://openrouter.ai/api/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "openai/gpt-4o-mini",
                       oauth: OAuthProviderConfig(
                           flow: .openRouterKeyExchange,
                           clientId: "",
                           authorizeURL: "https://openrouter.ai/auth",
                           tokenURL: "https://openrouter.ai/api/v1/auth/keys",
                           redirectURI: "aiapp://oauth/openrouter",
                           scope: ""
                       ),
                       maturity: .verified),
        ProviderPreset(id: "gemini", label: "Google Gemini", dialect: .openai,
                       defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai", needsKey: true,
                       editableBaseURL: false, defaultModel: "gemini-2.0-flash"),
        ProviderPreset(id: "mistral", label: "Mistral", dialect: .openai,
                       defaultBaseURL: "https://api.mistral.ai/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "mistral-small-latest"),
        ProviderPreset(id: "groq", label: "Groq", dialect: .openai,
                       defaultBaseURL: "https://api.groq.com/openai/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "llama-3.3-70b-versatile"),
        ProviderPreset(id: "deepseek", label: "DeepSeek", dialect: .openai,
                       defaultBaseURL: "https://api.deepseek.com/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "deepseek-chat"),
        // API-key only, for the same reason as OpenAI: the Grok subscription
        // token is only accepted by the grok-cli proxy.
        ProviderPreset(id: "xai", label: "xAI (Grok)", dialect: .openai,
                       defaultBaseURL: "https://api.x.ai/v1", needsKey: true,
                       editableBaseURL: false, defaultModel: "grok-3"),
        ProviderPreset(id: "together", label: "Together AI", dialect: .openai,
                       defaultBaseURL: "https://api.together.xyz/v1", needsKey: true,
                       editableBaseURL: false,
                       defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo"),
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
                       defaultBaseURL: "", needsKey: true,
                       editableBaseURL: true, defaultModel: "",
                       maturity: .verified),
        ProviderPreset(id: "custom-openai", label: "Beliebige OpenAI-API (URL + Key)", dialect: .openai,
                       defaultBaseURL: "", needsKey: true,
                       editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "custom-anthropic", label: "Eigener Server (Anthropic-kompatibel)", dialect: .anthropic,
                       defaultBaseURL: "", needsKey: false,
                       editableBaseURL: true, defaultModel: ""),
        ProviderPreset(id: "mlx", label: String(localized: "Lokal auf dem Gerät (MLX)"), dialect: .mlx,
                       defaultBaseURL: "", needsKey: false,
                       editableBaseURL: false, defaultModel: "",
                       maturity: .verified),
    ]

    static func preset(for id: String) -> ProviderPreset {
        catalog.first(where: { $0.id == id }) ?? catalog[0]
    }
}
