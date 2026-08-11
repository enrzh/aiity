import Foundation

/// Policy for on-device / LAN models. Small models produce garbage when given
/// tool schemas, huge system prompts, and high temperature — so we keep them
/// in a simple "chat first" mode by default.
///
/// # Two questions, two predicates
///
/// These used to be ONE list (`ConnectionProbe.localPresetIds`, now
/// `selfHostedPresetIds`), and that is exactly what broke tools on `sub2api`
/// and `custom-openai`:
///
/// 1. **Where does this endpoint live?** — `isSelfHosted`. A LAN box, a VPN
///    gateway, an on-device runtime: anything the user points the app at
///    themselves instead of a hosted first-party service. It drives *plumbing*
///    decisions — private/LAN host fetches, the "type your server address"
///    wizard, the native-Ollama models fallback, whether a missing API key is
///    an error, and whether unattended background traffic (smart suggestions)
///    may be sent there at all.
/// 2. **How capable is the model behind it?** — `usesSmallModelProfile`. Only
///    this one may withhold tool schemas, cap tokens, lower temperature and
///    swap in the reduced system prompt.
///
/// The sets overlap but are deliberately different: `sub2api` is a gateway to
/// frontier models (it is the app's image-generation test target, see
/// docs/provider-test-matrix.md) and `custom-openai` is "any OpenAI-compatible
/// API + URL" — usually a hosted provider. Both are self-hosted *endpoints*,
/// neither implies a small *model*. While one list served both, those two
/// providers silently lost web_search, fetch_url and generate_image.
enum LocalRuntimePolicy {

    /// Question 1 — endpoint locality. True for the bring-your-own-address
    /// presets (Ollama, LM Studio, LocalAI, custom-openai, sub2api) and for
    /// on-device MLX. **Never** use this to decide about tools.
    static func isSelfHosted(_ settings: ProviderSettings) -> Bool {
        [.mlx, .foundation].contains(settings.preset.dialect)
            || ConnectionProbe.isSelfHostedEndpoint(settings.presetId)
    }

    /// Question 2 — model capability. The genuine 1–8B LAN/on-device runtimes,
    /// and only those: a tool schema plus a long system prompt makes them
    /// invent `<tool_call>` spans and answer nonsense.
    ///
    /// `custom-openai` and `sub2api` are intentionally absent — see the type
    /// doc. A user who does point one of them at a tiny local model can opt in
    /// per provider via `ToolPolicy.never` (Anbieter → Werkzeuge).
    static let smallModelPresetIds: Set<String> = ["ollama", "lmstudio", "localai", "mlx", "apple-foundation"]

    static func usesSmallModelProfile(_ settings: ProviderSettings) -> Bool {
        usesSmallModelProfile(presetId: settings.presetId, dialect: settings.preset.dialect)
    }

    static func usesSmallModelProfile(presetId: String, dialect: ProviderDialect) -> Bool {
        dialect == .mlx || dialect == .foundation || smallModelPresetIds.contains(presetId)
    }

    /// The preset id MLX runs under (`MLXProvider` is only ever built for it).
    static let mlxPresetId = "mlx"

    // MARK: - Tool policy (per provider)

    /// What the user decided about tool definitions for one provider.
    /// `auto` follows `usesSmallModelProfile`; the other two are absolute and
    /// work in BOTH directions — force tools on for a capable LAN model, force
    /// them off for a tiny model behind an otherwise "cloud" preset.
    enum ToolPolicy: String, CaseIterable, Identifiable {
        case auto
        case always
        case never

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: return String(localized: "Automatisch")
            case .always: return String(localized: "Immer senden")
            case .never: return String(localized: "Nie senden")
            }
        }
    }

    /// `[presetId: ToolPolicy.rawValue]`. Absent entry = `.auto`.
    static let toolPolicyKey = "prefs.toolPolicyByProvider.v1"

    static func toolPolicy(forPresetId presetId: String) -> ToolPolicy {
        let stored = UserDefaults.standard.dictionary(forKey: toolPolicyKey) as? [String: String]
        guard let raw = stored?[presetId], let policy = ToolPolicy(rawValue: raw) else { return .auto }
        return policy
    }

    static func setToolPolicy(_ policy: ToolPolicy, forPresetId presetId: String) {
        var stored = (UserDefaults.standard.dictionary(forKey: toolPolicyKey) as? [String: String]) ?? [:]
        if policy == .auto {
            stored.removeValue(forKey: presetId)
        } else {
            stored[presetId] = policy.rawValue
        }
        if stored.isEmpty {
            UserDefaults.standard.removeObject(forKey: toolPolicyKey)
        } else {
            UserDefaults.standard.set(stored, forKey: toolPolicyKey)
        }
    }

    /// The legacy global switch ("Web-Tools für lokale Modelle", Mehr →
    /// Datenschutz). Still honoured: it is the DEFAULT for small-model
    /// runtimes when a provider has no explicit policy of its own.
    static var localToolsEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferences.allowLocalToolsKey)
    }

    /// What `.auto` resolves to right now for this provider — surfaced in the
    /// connection screen so "why is there no web search?" has a visible answer.
    static func autoSendsTools(presetId: String, dialect: ProviderDialect) -> Bool {
        !usesSmallModelProfile(presetId: presetId, dialect: dialect) || localToolsEnabled
    }

    /// Whether to attach native tool definitions in the API request.
    /// Off by default only for the genuine small-model runtimes; every other
    /// provider — cloud, gateway, custom OpenAI-compatible — gets the full set.
    static func shouldSendTools(_ settings: ProviderSettings) -> Bool {
        shouldSendTools(presetId: settings.presetId, dialect: settings.preset.dialect)
    }

    static func shouldSendTools(presetId: String, dialect: ProviderDialect) -> Bool {
        switch toolPolicy(forPresetId: presetId) {
        case .always: return true
        case .never: return false
        case .auto: return autoSendsTools(presetId: presetId, dialect: dialect)
        }
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
        guard settings.preset.dialect == .mlx || settings.preset.dialect == .foundation else { return recent }

        // The newest USER message is reserved before anything else.
        //
        // "Always keep the newest message" is not enough in a group round: by
        // the time the lead speaks, the newest message is a peer's turn, not
        // the question. With two 3 500-character contributions the lead
        // received exactly one of them and lost both the user's question and
        // the other agent's turn — while its brief told it to summarise the
        // agreement and deliver what the user asked for.
        let newestUser = recent.lastIndex { $0.role == .user }
        var keptIndices: Set<Int> = []
        var used = 0
        if let newestUser {
            keptIndices.insert(newestUser)
            used = recent[newestUser].text.count
        }
        for index in recent.indices.reversed() {
            guard !keptIndices.contains(index) else { continue }
            let cost = recent[index].text.count
            // The newest message is kept even if it alone blows the budget —
            // dropping the thing being replied to produces a confident answer
            // to nothing.
            if !keptIndices.isEmpty && used + cost > localTranscriptBudget { break }
            keptIndices.insert(index)
            used += cost
        }
        return recent.indices.filter { keptIndices.contains($0) }.map { recent[$0] }
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
