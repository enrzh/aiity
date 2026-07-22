import Foundation

/// Policy for on-device / LAN models. Small models produce garbage when given
/// tool schemas, huge system prompts, and high temperature — so we keep them
/// in a simple "chat first" mode by default.
enum LocalRuntimePolicy {

    /// True for Ollama, LM Studio, LocalAI, custom-openai, sub2api, MLX.
    static func isLocal(_ settings: ProviderSettings) -> Bool {
        settings.preset.dialect == .mlx || ConnectionProbe.isLocalStyle(settings.presetId)
    }

    /// Whether to attach native tool definitions in the API request.
    /// Off for local stacks — tool schemas make weak models invent fake calls
    /// and derail into nonsense. Cloud models keep tools.
    static func shouldSendTools(_ settings: ProviderSettings) -> Bool {
        !isLocal(settings)
    }

    /// Ultra-short system prompt for local models.
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
