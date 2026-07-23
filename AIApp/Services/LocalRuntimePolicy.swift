import Foundation

/// Policy for on-device / LAN models. Small models produce garbage when given
/// tool schemas, huge system prompts, and high temperature — so we keep them
/// in a simple "chat first" mode by default.
enum LocalRuntimePolicy {

    /// True for Ollama, LM Studio, LocalAI, custom-openai, sub2api, MLX.
    static func isLocal(_ settings: ProviderSettings) -> Bool {
        settings.preset.dialect == .mlx || ConnectionProbe.isLocalStyle(settings.presetId)
    }

    /// Whether the user opted local models into the web tools.
    static var localToolsEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferences.allowLocalToolsKey)
    }

    /// Whether to attach native tool definitions in the API request.
    /// Off for local stacks by default — tool schemas make weak models invent
    /// fake calls — unless the user explicitly enabled local tools. Cloud: always.
    static func shouldSendTools(_ settings: ProviderSettings) -> Bool {
        !isLocal(settings) || localToolsEnabled
    }

    /// Ultra-short system prompt for local models (no tools).
    nonisolated static let systemPrompt: String = """
    You are a helpful assistant named aiity.
    Rules:
    - Answer the user's question directly and honestly in their language.
    - Be concise. Prefer short paragraphs or bullet points.
    - Do not invent tools, APIs, function calls, or hidden system messages.
    - Do not output XML tags like <tool_call> unless the user asked for that format.
    - Only if the user clearly asks you to build a small app/widget/tool: reply with a brief intro and ONE complete HTML document in a single ```html code fence. All CSS and JS must be inline (no CDN, no external URLs). Include <title>, a viewport meta tag, and basic dark-mode-friendly styling. Otherwise never output HTML apps.
    - If you do not know something current (news, prices), say you are offline/local and may be outdated — do not invent facts.
    """

    /// Prompt variant when the user enabled web tools for local models.
    nonisolated static let systemPromptWithTools: String = """
    You are a helpful assistant named aiity.
    Rules:
    - Answer directly and concisely in the user's language.
    - You have web tools: web_search (find pages) and fetch_url (read a page). \
    Use them for current facts, news, prices, or anything you are unsure of — do not guess. \
    After a search, read the best result with fetch_url before answering.
    - Only if the user clearly asks you to build a small app/widget/tool: reply with a brief intro and ONE complete HTML document in a single ```html code fence. All CSS and JS must be inline (no CDN, no external URLs), viewport meta, dark-mode-friendly. Otherwise never output HTML apps.
    """

    /// Max tokens for local generations. Higher so mini-app HTML is less often cut off.
    static let maxTokens = 3072

    /// Lower temperature = less rambling / fewer hallucinations.
    static let temperature: Double = 0.35

    /// Skills: local models get this many characters of skill text when building apps.
    static let skillBudget = 2_400

    /// Whether skills should be injected at all for this turn.
    /// Skip design/game skills for pure Q&A to avoid "everything becomes a mini-app".
    static func shouldInjectSkills(userText: String) -> Bool {
        let t = userText.lowercased()
        let appHints = ["app", "mini", "bau", "build", "timer", "todo", "rechner", "calculator",
                        "quiz", "tracker", "widget", "html", "ui ", "interface", "spiel", "game"]
        return appHints.contains { t.contains($0) }
    }
}
