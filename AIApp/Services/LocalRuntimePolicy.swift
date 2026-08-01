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

    /// How much shared history an on-device model may be handed, in characters.
    ///
    /// The model weights are only part of the footprint — the KV cache grows
    /// with the prompt, and in a group round every agent re-reads the whole
    /// transcript every turn. A device report showed a 4-bit 4B model plus 25
    /// messages of group history reaching 2822 MB against 554 MB of headroom
    /// before iOS killed the app. A cloud provider does not care; a phone does.
    ///
    /// Characters rather than a message count on purpose: one pasted mini-app
    /// is worth more cache than twenty short turns, and a count cannot tell
    /// them apart.
    static let localTranscriptBudget = 6_000

    /// Trim `transcript` to what this provider should actually be given, newest
    /// first. Cloud providers keep the caller's window unchanged.
    ///
    /// Pure and static so the budget is testable without a model, a device, or
    /// a network.
    static func transcriptWindow(
        _ transcript: [ChatMessage],
        for settings: ProviderSettings,
        cloudLimit: Int
    ) -> [ChatMessage] {
        let recent = Array(transcript.suffix(cloudLimit))
        guard settings.preset.dialect == .mlx else { return recent }

        var kept: [ChatMessage] = []
        var used = 0
        for message in recent.reversed() {
            let cost = message.text.count
            // Always keep the newest message even if it alone blows the budget:
            // dropping the thing being replied to produces a confident answer
            // to nothing, which is worse than being slightly over.
            if !kept.isEmpty && used + cost > localTranscriptBudget { break }
            kept.append(message)
            used += cost
        }
        return kept.reversed()
    }

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
