import Foundation

/// One conversation. The session keeps the active thread's messages live in
/// `messages` and mirrors them back into `threads` on every persist.
struct ChatThread: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var messages: [ChatMessage] = []
    var editingContext: ChatSession.EditingContext?
    var updatedAt = Date()
}

/// Drives one user turn: stream the model's answer, execute requested tools,
/// feed results back, repeat (bounded), and extract a generated mini-app from
/// the final answer if one is present. App-wide object (EnvironmentObject);
/// all threads persist across app restarts.
@MainActor
final class ChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var busy = false
    @Published var statusLine: String?
    @Published var errorMessage: String?
    @Published var draftMiniApp: MiniAppDraft?
    /// Chat is presented as a full-screen cover from the Apps page; this drives
    /// it so the library can open the chat (incl. handing it a mini-app to edit).
    @Published var chatPresented = false
    @Published private(set) var threads: [ChatThread] = []
    private var activeThreadId = UUID()

    /// Set when the chat continues work on a saved mini-app.
    var editingContext: EditingContext?

    /// Prefix of the hidden user message that carries the full mini-app source
    /// into the model context (must survive Claude OAuth system-prompt trim).
    nonisolated static let miniAppSourceMarker = "[[MINIAPP_SOURCE]]"

    struct EditingContext: Codable, Equatable {
        var id: UUID
        var name: String
        var html: String
    }

    /// Full source as a conversation message (not system). Hidden in the UI.
    nonisolated static func sourcePinMessage(for context: EditingContext) -> ChatMessage {
        // Soft ceiling so a pathological paste doesn't blow the request; still
        // far above the old OAuth system budget (~3k) that dropped the source.
        let maxChars = 80_000
        let html = context.html.count > maxChars
            ? String(context.html.prefix(maxChars)) + "\n<!-- truncated for size -->"
            : context.html
        let text = """
        \(miniAppSourceMarker)
        Current mini-app "\(context.name)" — FULL source. Edit from THIS document only. \
        When changing it, return the complete updated HTML in one ```html fence.

        ```html
        \(html)
        ```
        """
        return ChatMessage(role: .user, text: text)
    }

    nonisolated static func isSourcePinMessage(_ message: ChatMessage) -> Bool {
        message.role == .user && message.text.hasPrefix(miniAppSourceMarker)
    }

    /// Tool rounds before we force a final answer (without tools).
    private static let maxToolRounds = 5
    /// At most one automatic validate→repair pass per user turn.
    private var repairUsedThisTurn = false
    private var lastUserTextForRepair: String?
    /// Soft issues from last mini-app validate (shown as banner, draft still kept).
    private var lastMiniAppWarnings: [String] = []
    /// In-flight send task — cancelled by `stop()`.
    private var activeTask: Task<Void, Never>?

    init() {
        restore()
    }

    /// Full quality bar for strong cloud models (API key path).
    nonisolated static let systemPrompt = """
    You are aiity ("AI it yourself"). You are first a normal, helpful chat assistant — answer questions, discuss, explain, write. Only build a "mini-app" when the user actually asks for an app/tool; otherwise just reply in plain conversation. Never emit a mini-app for a normal question.

    You can also generate media with tools:
    - generate_image(prompt, size?) — creates a picture and shows it to the user inline. Use when they ask for an image/illustration/logo/artwork.
    - generate_video(prompt) — creates a short video (slow, provider-dependent). Only on an explicit video request.
    After a generation tool runs, briefly tell the user what you made; the media is attached to your message automatically — do not paste base64 or URLs.

    When the user has enabled agent skills (listed under "Installed skills"), treat them as hard requirements for matching work — especially design systems, games, and charts. Do not invent a conflicting style.

    When the user asks you to create or change an app, answer with a short explanation plus a mini-app. Prefer ONE ```html fence (all CSS/JS inline). For larger apps you may also emit companion fences: ```css:style.css and ```js:app.js — they are bundled automatically. Rules:
    - Default is OFFLINE: no CDNs, no external fonts/scripts. Inline everything.
    - Set a short app name in <title>.
    - Icon: `<!-- emoji: X -->` and optionally `<!-- icon: sf.symbol.name -->` (SF Symbol, e.g. checklist, timer, cart).
    - Capability (opt-in only when needed):
      * default / `<!-- capability: offline -->` — no network (default).
      * `<!-- capability: network -->` — allow fetch/XHR + images over https (for APIs the user needs). Still no iframe browser chrome.
      * `<!-- capability: browser -->` — an in-app BROWSER that loads a real website inside the app. Use it whenever the user wants to OPEN, VIEW, DISPLAY, WRAP, EMBED or "access" a web page / web app / internal tool by looking at it (e.g. "open app.example.com in a mini-app"). Do NOT refuse these — you can't scrape a site's private data (CORS blocks that), but you CAN display the page and let the user log in and use it normally. For login/internal apps, navigate the whole view to the URL (top-level `location.href` or a link) — most such sites block being put in an <iframe>; use <iframe> only for embed-friendly pages. The user stays logged in across opens (session persists per app).
    - Bridge APIs:
      * `await miniapp.storage.get(key)` / `await miniapp.storage.set(key, value)`
      * `miniapp.haptic()`
      * `await miniapp.notify(title, body, inSeconds)`
      * `await miniapp.health.query(type, days)` — type: steps | activeEnergy | heartRate
      * `await miniapp.openExternal(url)` — opens Safari for a link
      * `miniapp.capability` — current tier string

    # Quality bar — every mini-app must feel like a real iOS app
    - COMPLETE functionality: no TODOs, no placeholders, no dead buttons. Every visible control works.
    - Load persisted state on start, save on every change (miniapp.storage). The app must survive being closed and reopened with all user data intact.
    - Mobile-first for an iPhone viewport: meta viewport, safe areas via env(safe-area-inset-*), no horizontal scrolling, touch targets of at least 44px.
    - Full dark mode: CSS custom properties for every color, switched via @media (prefers-color-scheme: dark).
    - Polished visuals: -apple-system font stack, consistent spacing scale, rounded cards, subtle transitions (150-250ms), pressed states on buttons.
    - Handle edge cases: empty states with a friendly hint, input validation with inline feedback, division-by-zero etc.
    - Use miniapp.haptic() on meaningful actions (add, complete, error).
    - Prefer more thorough, feature-complete apps over minimal sketches — include the 2-3 features a user would obviously expect next (edit, delete, undo, totals …).

    You DO have live internet access through your tools: web_search (find pages) and fetch_url (read a page's text). Whenever the user asks about current events, facts, prices, docs, or anything you are not sure of, CALL web_search — never answer such things from memory alone, and NEVER tell the user you cannot access the internet or browse the web. You can. If a search returns no results, say the search itself failed and try a different query; do not claim you lack internet capability. If the app depends on real-world data (prices, formulas, rules), research first and bake verified values in.
    Answer in the language the user writes in.
    """

    /// Compact rules for stronger cloud models that still need a shorter prompt
    /// (e.g. subscription OAuth budget). Not for tiny local models.
    nonisolated static let systemPromptCompact = """
    You are aiity. Helpful chat first. Only emit a mini-app when the user asks for an app/tool.
    Tools: web_search, fetch_url when you need current facts. After web_search, fetch_url the best 1–2 links before answering.
    Mini-apps = ONE ```html, offline by default (`<!-- emoji: X -->`, optional `<!-- icon: symbol -->`). Network only with `<!-- capability: network -->`.
    To OPEN/VIEW/EMBED a website or web app in-app (even "access X"), build a `<!-- capability: browser -->` mini-app that navigates to the URL (top-level location.href for login/internal apps; <iframe> only for embed-friendly sites). Do NOT refuse — you can display it and let the user log in; you just can't scrape its private data.
    Answer in the user's language.
    """

    /// Soft ceiling for the whole system prompt (skills get a dedicated slice below).
    static let promptSoftBudget = 16_000
    /// Dedicated budget so skills are not squeezed out by the long base prompt.
    static let skillCharBudgetCloud = 8_000
    static let skillCharBudgetCompact = 3_500

    /// Builds the system message. Enabled skills are always injected for cloud;
    /// local models get a roster always and full skill text when building apps.
    nonisolated static func buildSystemPrompt(
        settings: ProviderSettings,
        editing: EditingContext?,
        userText: String = ""
    ) -> String {
        // Local LAN / MLX: keep it dumb-simple so 1–8B models stay coherent.
        if LocalRuntimePolicy.isLocal(settings) {
            var system = LocalRuntimePolicy.shouldSendTools(settings)
                ? LocalRuntimePolicy.systemPromptWithTools
                : LocalRuntimePolicy.systemPrompt
            let roster = SkillStore.enabledRoster()
            if !roster.isEmpty {
                system += "\n\n" + roster
            }
            // Imported skills: always inject body (not only on "build app" keywords).
            let importedBudget = SkillStore.enabledImportedCount() > 0
                ? LocalRuntimePolicy.skillBudget
                : (LocalRuntimePolicy.shouldInjectSkills(userText: userText) ? LocalRuntimePolicy.skillBudget : 0)
            if importedBudget > 0 {
                let skillBlock = SkillStore.enabledInstructions(maxChars: importedBudget)
                if !skillBlock.isEmpty {
                    system += "\n\n# Skills (must follow)\n\(skillBlock)"
                }
            }
            if let context = editing {
                system += """


                # EDITING MINI-APP
                You are editing "\(context.name)". The COMPLETE current HTML is in the \
                conversation as a user message starting with \(miniAppSourceMarker). \
                Base every change on that source. When changing the app, output the FULL \
                updated document in one ```html fence. Do not ask the user to paste code.
                """
            }
            return system
        }

        let caps = ConnectionProbe.capabilities(for: settings)
        let useCompact = !caps.miniAppPro
        var system = useCompact ? systemPromptCompact : systemPrompt
        if useCompact {
            system += "\n\n" + MiniAppValidator.templateOnlyModePrompt
            let shortTemplates = MiniAppValidator.templates
                .map { "- `\($0.id)`: \($0.name)" }
                .joined(separator: "\n")
            system += "\n\nTemplates:\n\(shortTemplates)"
        } else {
            system += "\n\n" + MiniAppValidator.templatesPromptSection
        }

        let skillBudget = useCompact ? skillCharBudgetCompact : skillCharBudgetCloud
        let skillBlock = SkillStore.enabledInstructions(maxChars: skillBudget)
        // Place skills near the END of the system prompt (stronger model adherence)
        // and list imported skill names first.
        var tail = ""
        // Full HTML lives in a pinned conversation message (see sourcePinMessage).
        // Only a short pointer here so Claude OAuth's ~3k system trim cannot drop
        // the only copy of the source.
        if let context = editing {
            tail += """


            # EDITING MINI-APP
            You are editing "\(context.name)". The COMPLETE current HTML is in the \
            conversation as a user message starting with \(miniAppSourceMarker). \
            Base every change on that source. When changing the app, output the FULL \
            updated document in one ```html fence. Do not ask the user to paste code \
            you already have in that message.
            """
        }
        if !skillBlock.isEmpty {
            let nImport = SkillStore.enabledImportedCount()
            tail += """


            # USER-INSTALLED SKILLS — MANDATORY
            \(nImport) imported skill(s) are enabled. Follow them with HIGHEST priority for matching tasks \
            (UI, design, docs, testing, tools). Do not skip, summarize away, or contradict them. \
            Built-in skills are secondary.

            \(skillBlock)

            Remember: apply the skills above in your next answer and any mini-app HTML you emit.
            """
        }
        return system + tail
    }

    /// Builds a browser mini-app for a URL without any model round.
    private func buildWebApp(url: String, userText: String) {
        messages.append(ChatMessage(role: .user, text: userText))
        let host = WebAppBuilder.host(of: url)
        let html = WebAppBuilder.html(urlString: url)
        let reply = "Hier ist eine Browser-Mini-App für **\(host)**. „Vorschau“ öffnet sie sofort, „Behalten“ speichert sie unter Apps. Beim ersten Öffnen fragt sie nach Internet-Erlaubnis — danach bleibst du auf der Seite eingeloggt."
        // Embed the HTML fence so the draft survives a restart (ChatView hides it).
        let assistantText = reply + "\n\n```html\n" + html + "\n```"
        messages.append(ChatMessage(role: .assistant, text: assistantText))
        draftMiniApp = MiniAppDraft.extract(from: assistantText)
        persist()
        Analytics.track("webapp_built")
    }

    func send(_ input: String, settings: ProviderSettings) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        errorMessage = nil
        // "Öffne <url>" builds a browser mini-app deterministically — the model
        // tends to over-refuse "accessing" a site, so don't route it through one.
        if editingContext == nil, let openURL = WebAppBuilder.detectOpenRequest(text) {
            buildWebApp(url: openURL, userText: text)
            return
        }
        repairUsedThisTurn = false
        lastUserTextForRepair = text
        // Always refresh system prompt so provider/skills changes apply immediately.
        let system = Self.buildSystemPrompt(
            settings: settings,
            editing: editingContext,
            userText: text
        )
        if let idx = messages.firstIndex(where: { $0.role == .system }) {
            messages[idx].text = system
        } else {
            messages.insert(ChatMessage(role: .system, text: system), at: 0)
        }
        // Pin full mini-app HTML into the conversation (hidden in UI) so the
        // model always sees it — even when OAuth trims the system prompt.
        ensureSourcePinned()
        // Local models struggle with long histories — keep a short window.
        if LocalRuntimePolicy.isLocal(settings) {
            trimHistoryForLocal()
            ensureSourcePinned()
        }
        messages.append(ChatMessage(role: .user, text: text))
        persist()
        busy = true
        AgentLiveActivityController.shared.start(prompt: text)

        activeTask?.cancel()
        activeTask = Task { @MainActor in
            defer {
                if !Task.isCancelled {
                    busy = false
                    statusLine = nil
                    persist()
                }
            }
            var runSettings = settings
            let apiKey = await AuthStore.effectiveKey(for: runSettings)
            if Task.isCancelled { return }
            // ChatGPT OAuth: ensure a Codex-safe model id is selected.
            if runSettings.presetId == "openai", apiKey.hasPrefix(AuthStore.oauthMarker) {
                let codexIds = ModelCatalogCache.codexOAuthModels().map(\.id)
                let current = runSettings.effectiveModel
                if current.isEmpty {
                    runSettings.model = codexIds.first ?? "gpt-4.1"
                } else if !codexIds.contains(current),
                          (current.contains("gpt-3") || current.contains("davinci") || current == "gpt-4") {
                    // Obvious non-Codex ids → swap to a known Codex model for this turn.
                    runSettings.model = codexIds.first(where: { $0.contains("4.1") }) ?? codexIds.first ?? "gpt-4.1"
                }
            }
            if runSettings.preset.dialect != .mlx,
               runSettings.effectiveModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = "Kein Modell gewählt — Mehr → KI-Anbieter → Modell aus der Liste wählen."
                busy = false
                AgentLiveActivityController.shared.fail(message: errorMessage ?? "Kein Modell")
                return
            }
            if runSettings.preset.needsKey && apiKey.isEmpty && !ConnectionProbe.isLocalStyle(runSettings.presetId) {
                errorMessage = "Kein API-Key / Abo-Login — unter KI-Anbieter ein Konto verbinden."
                busy = false
                AgentLiveActivityController.shared.fail(message: errorMessage ?? "Kein Key")
                return
            }
            if runSettings.presetId == "openai",
               apiKey.hasPrefix(AuthStore.oauthMarker),
               AuthStore.activeAccountChatGPTId(for: "openai") == nil {
                // Still try — some tokens work without account header; warn softly.
                #if DEBUG
                print("OpenAI OAuth: missing chatgpt_account_id — Codex may reject")
                #endif
            }
            let provider = runSettings.makeProvider(apiKey: apiKey)
            let tools = await ToolRegistry.makeTools(settings: runSettings, apiKey: apiKey)
            await runTurn(provider: provider, tools: tools)
            if Task.isCancelled { return }
            finishLiveActivityAfterTurn()
        }
    }

    /// Only hard-fail the Live Activity when the turn produced no usable answer.
    private func finishLiveActivityAfterTurn() {
        if let draft = draftMiniApp {
            AgentLiveActivityController.shared.complete(summary: "Mini-App: \(draft.name)")
            return
        }
        let hasAnswer = messages.contains {
            $0.role == .assistant
                && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.mediaIds.isEmpty)
        }
        if hasAnswer {
            // Soft tool warnings (e.g. image gen failed) must not become “aiity Fehler”.
            AgentLiveActivityController.shared.complete(
                summary: errorMessage == nil ? "Antwort fertig" : "Fertig (siehe Hinweis im Chat)"
            )
            return
        }
        if let err = errorMessage, !err.isEmpty {
            AgentLiveActivityController.shared.fail(message: err)
        } else {
            AgentLiveActivityController.shared.fail(message: "Keine Antwort vom Modell — Modell/Abo prüfen und erneut senden.")
        }
    }

    /// Keep system + last few turns so 1–8B models don't lose the plot.
    private func trimHistoryForLocal(maxMessages: Int = 12) {
        let system = messages.filter { $0.role == .system }
        let pins = messages.filter { Self.isSourcePinMessage($0) }
        var rest = messages.filter { $0.role != .system && !Self.isSourcePinMessage($0) }
        // Drop tool scaffolding that confuses locals
        rest.removeAll { $0.role == .tool }
        for i in rest.indices where rest[i].role == .assistant {
            rest[i].toolCalls = []
        }
        if rest.count > maxMessages {
            rest = Array(rest.suffix(maxMessages))
        }
        // System → source pin → recent turns (pin must not be trimmed away).
        messages = system + pins.suffix(1) + rest
    }

    /// Insert / refresh the hidden full-source user message while editing.
    func ensureSourcePinned() {
        guard let context = editingContext else { return }
        let pin = Self.sourcePinMessage(for: context)
        if let idx = messages.firstIndex(where: { Self.isSourcePinMessage($0) }) {
            messages[idx] = pin
            return
        }
        // After system message if present, else at front.
        if let sys = messages.firstIndex(where: { $0.role == .system }) {
            messages.insert(pin, at: sys + 1)
        } else {
            messages.insert(pin, at: 0)
        }
    }

    /// After "Behalten", keep the pin in sync with the new HTML.
    func updateEditingSource(html: String, name: String? = nil) {
        guard var ctx = editingContext else { return }
        ctx.html = html
        if let name, !name.isEmpty { ctx.name = name }
        editingContext = ctx
        ensureSourcePinned()
        persist()
    }

    /// Cancel the current generation (network stream / tool loop).
    func stop() {
        activeTask?.cancel()
        activeTask = nil
        busy = false
        statusLine = nil
        AgentLiveActivityController.shared.cancel()
        if let last = messages.indices.last,
           messages[last].role == .assistant,
           messages[last].text.isEmpty,
           messages[last].toolCalls.isEmpty {
            messages.remove(at: last)
        }
        errorMessage = nil
        statusLine = "Gestoppt"
        persist()
        // Clear status after a beat so the chrome doesn't stay sticky.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if statusLine == "Gestoppt" { statusLine = nil }
        }
    }

    /// App moved to background while agent may still be running.
    func handleAppBackground() {
        if busy {
            AgentLiveActivityController.shared.enterBackgroundWhileBusy()
        }
    }

    /// App became active again.
    func handleAppForeground() {
        AgentLiveActivityController.shared.enterForeground()
        if busy {
            AgentLiveActivityController.shared.update(phase: statusLine ?? "Arbeitet weiter…")
        }
    }

    private func runTurn(provider: LLMProvider, tools: [AgentTool]) async {
        let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.spec.name, $0) })
        // Media generated during this turn is shown on the closing answer.
        var pendingMediaIds: [String] = []
        let wantsApp = LocalRuntimePolicy.shouldInjectSkills(userText: lastUserTextForRepair ?? "")

        for round in 0..<Self.maxToolRounds {
            // After several tool rounds, force a tool-free completion so mini-apps
            // are not abandoned mid-research.
            let allowTools = !tools.isEmpty && round < Self.maxToolRounds - 1
            let roundTools = allowTools ? tools : []
            let specs = roundTools.map(\.spec)

            if !allowTools, round > 0 {
                messages.append(ChatMessage(
                    role: .user,
                    text: wantsApp
                        ? "Stop using tools. Output the complete mini-app NOW as ONE ```html document (inline CSS/JS, viewport, title, emoji comment). Full HTML only."
                        : "Stop using tools. Give your final answer now based on the tool results above."
                ))
                statusLine = wantsApp ? "Baut Mini-App…" : "Schließt ab…"
            } else {
                statusLine = "Schreibt…"
            }

            messages.append(ChatMessage(role: .assistant, text: ""))
            let assistantIndex = messages.count - 1
            var requestedCalls: [ToolCallData] = []
            AgentLiveActivityController.shared.update(phase: statusLine, progress: 0.25 + Double(round) * 0.1)

            do {
                var charBudget = 0
                for try await event in provider.streamChat(messages: Array(messages[..<assistantIndex]), tools: specs) {
                    if Task.isCancelled { return }
                    switch event {
                    case .textDelta(let delta):
                        messages[assistantIndex].text += delta
                        charBudget += delta.count
                        if charBudget >= 200 {
                            charBudget = 0
                            let preview = String(messages[assistantIndex].text.suffix(60))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            AgentLiveActivityController.shared.update(
                                phase: statusLine ?? "Schreibt…",
                                detail: preview.isEmpty ? nil : preview,
                                progress: nil
                            )
                            // Live mini-app draft while HTML streams (don’t wait for fence close).
                            maybePublishStreamingDraft(from: messages[assistantIndex].text)
                        }
                    case .toolCall(let call):
                        if allowTools {
                            requestedCalls.append(call)
                            AgentLiveActivityController.shared.update(
                                phase: Self.statusText(for: call),
                                detail: Self.statusDetail(for: call),
                                progress: 0.4
                            )
                        }
                        // If tools disabled this round, ignore tool_call events.
                    case .done:
                        break
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                if let urlError = error as? URLError, urlError.code == .cancelled { return }
                // Keep partial text if any — often contains half a mini-app.
                if messages[assistantIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.remove(at: assistantIndex)
                }
                let friendly = NetworkErrorFriendly.message(for: error)
                // Try to salvage HTML from any earlier assistant message.
                if draftMiniApp == nil {
                    for msg in messages.reversed() where msg.role == .assistant {
                        if let draft = MiniAppDraft.extract(from: msg.text) {
                            draftMiniApp = draft
                            errorMessage = friendly + " — unvollständige Mini-App gerettet, bitte prüfen."
                            return
                        }
                    }
                }
                errorMessage = friendly
                AgentLiveActivityController.shared.fail(message: friendly)
                return
            }
            if Task.isCancelled { return }

            messages[assistantIndex].toolCalls = requestedCalls
            if requestedCalls.isEmpty {
                messages[assistantIndex].mediaIds = pendingMediaIds
                await handleAssistantFinished(provider: provider, tools: tools, assistantIndex: assistantIndex)
                return
            }

            for call in requestedCalls {
                statusLine = Self.statusText(for: call)
                AgentLiveActivityController.shared.update(
                    phase: statusLine,
                    detail: Self.statusDetail(for: call),
                    progress: nil
                )
                let result = await toolsByName[call.name]?.run(argumentsJSON: call.argumentsJSON)
                    ?? ToolRunResult("Error: unknown tool \(call.name)")
                pendingMediaIds.append(contentsOf: result.mediaIds)
                messages.append(ChatMessage(role: .tool, text: result.text, toolCallId: call.id, toolName: call.name))
            }
            statusLine = "Schreibt…"
            AgentLiveActivityController.shared.update(phase: "Schreibt…", progress: 0.55)
        }

        // Absolute fallback: force one more no-tool completion.
        await forceFinalAnswer(provider: provider, wantsApp: wantsApp, pendingMediaIds: pendingMediaIds)
    }

    /// Last-chance generation without tools when the model only ran tools.
    private func forceFinalAnswer(provider: LLMProvider, wantsApp: Bool, pendingMediaIds: [String]) async {
        messages.append(ChatMessage(
            role: .user,
            text: wantsApp
                ? "CRITICAL: Output ONLY one complete ```html mini-app now (full document, inline CSS/JS). No tools, no excuses."
                : "Give your final answer now. No more tools."
        ))
        statusLine = wantsApp ? "Finalisiert Mini-App…" : "Finalisiert…"
        AgentLiveActivityController.shared.update(phase: statusLine, progress: 0.85)
        messages.append(ChatMessage(role: .assistant, text: ""))
        let assistantIndex = messages.count - 1
        do {
            for try await event in provider.streamChat(messages: Array(messages[..<assistantIndex]), tools: []) {
                if Task.isCancelled { return }
                if case .textDelta(let delta) = event {
                    messages[assistantIndex].text += delta
                }
            }
        } catch {
            if Task.isCancelled { return }
            if messages[assistantIndex].text.isEmpty {
                messages.remove(at: assistantIndex)
                errorMessage = NetworkErrorFriendly.message(for: error)
                return
            }
        }
        messages[assistantIndex].mediaIds = pendingMediaIds
        await handleAssistantFinished(provider: provider, tools: [], assistantIndex: assistantIndex)
        if draftMiniApp == nil,
           !messages.contains(where: {
               $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           }) {
            errorMessage = "Antwort unvollständig — bitte erneut senden (kürzere Anfrage hilft)."
        }
    }

    /// Publish a partial mini-app card as soon as a ```html fence has enough content.
    private func maybePublishStreamingDraft(from text: String) {
        guard text.localizedCaseInsensitiveContains("```html") || text.localizedCaseInsensitiveContains("<!doctype") else {
            return
        }
        guard let draft = MiniAppDraft.extract(from: text), draft.html.count >= 120 else { return }
        // Only upgrade; don’t clear a better final draft with a shorter one later in another path.
        if let existing = draftMiniApp, existing.html.count > draft.html.count + 80 { return }
        draftMiniApp = draft
        if statusLine == "Schreibt…" || statusLine == nil {
            statusLine = "Mini-App wird gebaut…"
        }
    }

    /// Validate mini-app HTML (multi-file aware); if broken, one repair turn (no tools).
    private func handleAssistantFinished(provider: LLMProvider, tools: [AgentTool], assistantIndex: Int) async {
        let text = messages[assistantIndex].text
        if let bundle = MiniAppBundleParser.extract(from: text) {
            let runnable = MiniAppValidator.prepareHTML(bundle.bundledHTML())
            let validation = MiniAppValidator.validate(runnable)
            let draft = MiniAppDraft(
                name: bundle.name,
                emoji: bundle.emoji,
                html: runnable,
                filesJSON: bundle.filesJSON(),
                iconSymbol: bundle.iconSymbol
            )
            // Always surface a draft card if we have usable HTML.
            if validation.isValid || runnable.count >= 80 {
                draftMiniApp = draft
                Analytics.track("miniapp_draft", ["multi": bundle.isMultiFile ? "1" : "0"])
                if !validation.issues.isEmpty {
                    lastMiniAppWarnings = validation.issues
                    // Soft banner — does not block keep/preview.
                    errorMessage = "Mini-App bereit (Hinweise: " + validation.issues.prefix(2).joined(separator: "; ") + ")"
                }
                // Optional one repair if hard structural issues remain and HTML tiny
                if !validation.isValid, !repairUsedThisTurn, runnable.count < 200 {
                    repairUsedThisTurn = true
                    statusLine = "Korrigiert Mini-App…"
                    AgentLiveActivityController.shared.update(phase: "Korrigiert Mini-App…", progress: 0.75)
                    let repair = MiniAppValidator.repairPrompt(
                        originalUserRequest: lastUserTextForRepair,
                        html: runnable,
                        issues: validation.issues
                    )
                    messages.append(ChatMessage(role: .user, text: repair))
                    // Repair without tools so we don't re-enter the tool loop.
                    await runTurn(provider: provider, tools: [])
                }
                return
            }
            if repairUsedThisTurn {
                draftMiniApp = draft
                errorMessage = "Mini-App-Prüfung: " + validation.issues.joined(separator: "; ")
                return
            }
            repairUsedThisTurn = true
            statusLine = "Korrigiert Mini-App…"
            AgentLiveActivityController.shared.update(phase: "Korrigiert Mini-App…", progress: 0.75)
            let repair = MiniAppValidator.repairPrompt(
                originalUserRequest: lastUserTextForRepair,
                html: runnable,
                issues: validation.issues
            )
            messages.append(ChatMessage(role: .user, text: repair))
            await runTurn(provider: provider, tools: [])
            return
        }
        draftMiniApp = MiniAppDraft.extract(from: text)
        if draftMiniApp == nil, text.localizedCaseInsensitiveContains("```html") {
            // Last salvage attempt with prepareHTML
            if let html = MiniAppBundleParser.extractHTMLFence(from: text) {
                let meta = MiniAppBundleParser.metaFromHTML(html)
                draftMiniApp = MiniAppDraft(name: meta.name, emoji: meta.emoji, html: html, iconSymbol: meta.iconSymbol)
            }
        }
    }

    private static func statusText(for call: ToolCallData) -> String {
        switch call.name {
        case "web_search": return "Sucht im Web…"
        case "fetch_url": return "Liest Seite…"
        case "generate_image": return "Erstellt Bild…"
        case "generate_video": return "Erstellt Video…"
        default: return "Tool: \(call.name)"
        }
    }

    private static func statusDetail(for call: ToolCallData) -> String {
        let arguments = toolArguments(call.argumentsJSON)
        switch call.name {
        case "web_search": return arguments["query"] as? String ?? ""
        case "fetch_url": return arguments["url"] as? String ?? ""
        case "generate_image", "generate_video":
            return String((arguments["prompt"] as? String ?? "").prefix(60))
        default: return call.name
        }
    }

    // MARK: - Threads

    func newThread() {
        guard !busy else { return }
        syncActiveIntoThreads()
        let thread = ChatThread()
        threads.insert(thread, at: 0)
        activeThreadId = thread.id
        loadActiveThread()
        persist()
    }

    func switchTo(threadId: UUID) {
        guard !busy, threadId != activeThreadId,
              threads.contains(where: { $0.id == threadId }) else { return }
        syncActiveIntoThreads()
        activeThreadId = threadId
        loadActiveThread()
        persist()
    }

    func deleteThread(_ threadId: UUID) {
        guard !busy else { return }
        threads.removeAll { $0.id == threadId }
        if threadId == activeThreadId {
            if let next = threads.max(by: { $0.updatedAt < $1.updatedAt }) {
                activeThreadId = next.id
            } else {
                let fresh = ChatThread()
                threads = [fresh]
                activeThreadId = fresh.id
            }
            loadActiveThread()
        }
        persist()
    }

    var activeThreadTitle: String {
        threads.first(where: { $0.id == activeThreadId })?.title ?? ""
    }

    /// Entry point from the library / mini-app sheet: continue a saved mini-app.
    func startEditing(id: UUID, name: String, html: String) {
        newThread()
        editingContext = EditingContext(id: id, name: name, html: html)
        messages = [
            ChatMessage(
                role: .assistant,
                text: "Du bearbeitest **\(name)**. Der aktuelle Quellcode ist an die KI übergeben — beschreib nur, was ich ändern oder verbessern soll (Design, Features, Icon, Netzwerk …)."
            ),
        ]
        ensureSourcePinned()
        draftMiniApp = nil
        chatPresented = true
        persist()
    }

    /// Preview / unsaved draft → new edit thread (keep will insert a new app).
    func startEditingDraft(name: String, html: String, emoji: String = "✨") {
        newThread()
        editingContext = EditingContext(id: UUID(), name: name, html: html)
        messages = [
            ChatMessage(
                role: .assistant,
                text: "Vorschau von **\(name)** \(emoji). Quellcode ist an die KI übergeben — sag, was ich anpassen soll; danach speichern wir die neue Version."
            ),
        ]
        ensureSourcePinned()
        draftMiniApp = nil
        chatPresented = true
        persist()
    }

    private func loadActiveThread() {
        let thread = threads.first(where: { $0.id == activeThreadId }) ?? ChatThread()
        messages = thread.messages
        editingContext = thread.editingContext
        errorMessage = nil
        statusLine = nil
        draftMiniApp = messages.last(where: { $0.role == .assistant }).flatMap { MiniAppDraft.extract(from: $0.text) }
    }

    private func syncActiveIntoThreads() {
        guard let index = threads.firstIndex(where: { $0.id == activeThreadId }) else {
            if !messages.isEmpty {
                threads.insert(currentSnapshotThread(), at: 0)
            }
            return
        }
        threads[index] = currentSnapshotThread(existing: threads[index])
    }

    private func currentSnapshotThread(existing: ChatThread? = nil) -> ChatThread {
        var thread = existing ?? ChatThread(id: activeThreadId)
        thread.id = activeThreadId
        thread.messages = messages
        thread.editingContext = editingContext
        if !messages.isEmpty { thread.updatedAt = .now }
        if thread.title.isEmpty {
            if let context = editingContext {
                thread.title = "✏️ \(context.name)"
            } else if let firstUser = messages.first(where: { $0.role == .user }) {
                thread.title = String(firstUser.text.prefix(48))
            }
        }
        return thread
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var threads: [ChatThread]
        var activeThreadId: UUID
    }

    /// v1 single-conversation format, migrated on first launch.
    private struct LegacySnapshot: Codable {
        var messages: [ChatMessage]
        var editingContext: EditingContext?
    }

    private static let storeURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("chat-threads.json")
    }()

    private static let legacyStoreURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-session.json")
    }()

    /// Public hook so UI can flush after clearing edit mode etc.
    func persistPublic() { persist() }

    private func persist() {
        syncActiveIntoThreads()
        let snapshot = Snapshot(threads: threads, activeThreadId: activeThreadId)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }

    private func restore() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           !snapshot.threads.isEmpty {
            threads = snapshot.threads
            activeThreadId = snapshot.threads.contains(where: { $0.id == snapshot.activeThreadId })
                ? snapshot.activeThreadId
                : snapshot.threads[0].id
        } else if let data = try? Data(contentsOf: Self.legacyStoreURL),
                  let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data),
                  !legacy.messages.isEmpty {
            var thread = ChatThread(messages: legacy.messages, editingContext: legacy.editingContext)
            if let firstUser = legacy.messages.first(where: { $0.role == .user }) {
                thread.title = String(firstUser.text.prefix(48))
            }
            threads = [thread]
            activeThreadId = thread.id
            try? FileManager.default.removeItem(at: Self.legacyStoreURL)
        } else {
            let fresh = ChatThread()
            threads = [fresh]
            activeThreadId = fresh.id
        }
        loadActiveThread()
    }
}

/// A mini-app the model just produced, before the user decides to keep it.
struct MiniAppDraft: Equatable {
    var name: String
    var emoji: String
    var html: String
    /// Companion files JSON (multi-file); default empty object.
    var filesJSON: String = "{}"
    var iconSymbol: String? = nil

    static func extract(from text: String) -> MiniAppDraft? {
        guard let bundle = MiniAppBundleParser.extract(from: text) else { return nil }
        return MiniAppDraft(
            name: bundle.name,
            emoji: bundle.emoji,
            html: bundle.bundledHTML(),
            filesJSON: bundle.filesJSON(),
            iconSymbol: bundle.iconSymbol
        )
    }
}
