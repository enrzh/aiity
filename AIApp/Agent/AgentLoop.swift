import Foundation

/// One conversation. The session keeps the active thread's messages live in
/// `messages` and mirrors them back into `threads` on every persist.
struct ChatThread: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var messages: [ChatMessage] = []
    var editingContext: ChatSession.EditingContext?
    var updatedAt = Date()
    /// Agents taking part in this conversation. Empty = an ordinary one-on-one
    /// chat with the assistant; one or more turns it into a group where those
    /// agents answer alongside it.
    var participantAgentIds: [UUID] = []

    var isGroup: Bool { !participantAgentIds.isEmpty }

    init(
        id: UUID = UUID(),
        title: String = "",
        messages: [ChatMessage] = [],
        editingContext: ChatSession.EditingContext? = nil,
        updatedAt: Date = Date(),
        participantAgentIds: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.editingContext = editingContext
        self.updatedAt = updatedAt
        self.participantAgentIds = participantAgentIds
    }

    // Hand-written so a NEW field can be added without orphaning every stored
    // thread. Swift's synthesized decoder does NOT fall back to a property's
    // default value — a missing key throws, one throw fails the whole array,
    // and the app comes up with an empty chat list on top of a full file.
    private enum CodingKeys: String, CodingKey {
        case id, title, messages, editingContext, updatedAt, participantAgentIds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        messages = try values.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        editingContext = try values.decodeIfPresent(ChatSession.EditingContext.self, forKey: .editingContext)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        participantAgentIds = try values.decodeIfPresent([UUID].self, forKey: .participantAgentIds) ?? []
    }

    /// One line of the most recent content, for the conversation list.
    var preview: String {
        for message in messages.reversed() {
            guard !ChatSession.isSourcePinMessage(message) else { continue }
            switch message.role {
            case .user, .assistant:
                let text = message.text
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return String(text.prefix(140)) }
                if !message.mediaIds.isEmpty { return "📷 Bild" }
            case .tool, .system:
                continue
            }
        }
        return String(localized: "Noch keine Nachrichten")
    }
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
    /// Drives the push from the conversation list into a chat. Nil = list shown.
    @Published var openThreadId: UUID?
    private var activeThreadId = UUID()

    /// Chips offered in the chat empty state. THE composition point: whatever
    /// wants to influence those four slots — the curated pool, the optional
    /// model-generated ideas — goes through `refreshEmptyStateSuggestions()`,
    /// never through the view. Computed once per thread activation so a body
    /// recompute (keyboard focus, busy toggle) can never re-deal the row.
    @Published private(set) var emptyStateSuggestions: [String] = []
    /// The set the PREVIOUS conversation showed — a soft exclusion so a new
    /// chat does not open with the same four ideas. In memory only: this is
    /// deliberately not in the persisted Snapshot (the format is hand-rolled
    /// and fragile), and repeating across launches is harmless.
    private var previousSuggestionSet: Set<String> = []
    private var lastSuggestionThreadId: UUID?
    /// Ideas the user's own cloud provider proposed (see ChatSuggestionService).
    /// Empty whenever the feature is off, ungated or unavailable.
    private var modelSuggestions: [String] = []

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
    /// Validate → fix rounds already spent this turn (see ChatMode).
    private var repairPassesThisTurn = 0
    private var lastUserTextForRepair: String?
    /// Soft issues from last mini-app validate (shown as banner, draft still kept).
    private var lastMiniAppWarnings: [String] = []
    /// In-flight send task — cancelled by `stop()`.
    private var activeTask: Task<Void, Never>?

    // MARK: - Interrupted turns (background hardening)

    /// A turn iOS cut short (background grant expired, or the process was
    /// killed) that the user may replay. Nil unless there is something to
    /// offer — see `evaluateInterruptedTurn()` for when it is set.
    @Published private(set) var interruptedTurn: PendingTurn?

    /// When the running turn began. Part of the checkpoint, and what the
    /// stop-beats-resume contract compares a persisted stop request against.
    private var turnStartedAt: Date?
    /// Throttle for the streaming checkpoint.
    private var lastCheckpointAt: Date?
    private static let checkpointInterval: TimeInterval = 2
    /// Set when the turn ended because the app was suspended, not because
    /// anything failed. Keeps the turn's `defer` from deleting the checkpoint
    /// the resume offer depends on, and keeps the Live Activity on "Pausiert"
    /// instead of flipping it to an error.
    private var turnInterruptedBySuspension = false
    /// Block-based NotificationCenter observers are not auto-removed.
    private var stopRequestObserver: NSObjectProtocol?

    #if DEBUG
    /// Ordered record of what `handleBackgroundTimeExpiring()` did, so the
    /// sequence itself (not just its side effects) is testable.
    private(set) var expirationSteps: [String] = []
    #endif

    init() {
        restore()
        observeLiveActivityStopRequests()
        // Cold launch is one of the two moments the stop-vs-resume contract is
        // evaluated (the other is foreground). Runs AFTER restore() so the
        // conversations a decision may repair are actually loaded.
        evaluateInterruptedTurn()
    }

    deinit {
        if let stopRequestObserver {
            NotificationCenter.default.removeObserver(stopRequestObserver)
        }
    }

    /// Full quality bar for strong cloud models (API key path).
    nonisolated static let systemPrompt = """
    You are aiity ("AI it yourself"). You are first a normal, helpful chat assistant — answer questions, discuss, explain, write. Only build a "mini-app" when the user actually asks for an app/tool; otherwise just reply in plain conversation. Never emit a mini-app for a normal question.

    You can also generate media with tools:
    - generate_image(prompt, size?) — creates a picture and shows it to the user inline. Use when they ask for an image/illustration/logo/artwork.
    After a generation tool runs, briefly tell the user what you made; the media is attached to your message automatically — do not paste base64 or URLs.

    If an `ask_agent` tool is offered, the user has configured specialist agents. You are the lead: when a task matches one of their roles better than your own — deep research, review, translation, a second opinion from a different model — delegate it with ask_agent, then use the answer in your reply. Give the agent everything it needs in the task text; it cannot see this conversation. Do not delegate trivial work you can just do, and never announce a delegation you did not make.

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
        let reply = String(localized: "Hier ist eine Browser-Mini-App für **\(host)**. „Vorschau“ öffnet sie sofort, „Behalten“ speichert sie unter Apps. Beim ersten Öffnen fragt sie nach Internet-Erlaubnis — danach bleibst du auf der Seite eingeloggt.")
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
        // Which provider a run was using is the first question about any crash
        // in this app, so it goes into the run record, not just a breadcrumb.
        DiagnosticsRecorder.shared.noteProvider(settings.presetId, model: settings.model)
        DiagnosticsRecorder.shared.record(
            "chat",
            "Senden · \(text.count) Zeichen · \(activeThreadIsGroup ? "Gruppe" : "Einzel")"
                + " · Modus \(AppPreferences.storedChatMode.rawValue)"
        )
        // A group thread is a different conversation shape entirely — the
        // participants answer, not the mini-app-building assistant.
        if activeThreadIsGroup {
            sendToGroup(text, settings: settings)
            return
        }
        // "Öffne <url>" builds a browser mini-app deterministically — the model
        // tends to over-refuse "accessing" a site, so don't route it through one.
        if editingContext == nil, let openURL = WebAppBuilder.detectOpenRequest(text) {
            buildWebApp(url: openURL, userText: text)
            return
        }
        repairPassesThisTurn = 0
        lastUserTextForRepair = text
        // Always refresh system prompt so provider/skills changes apply immediately.
        let system = Self.buildSystemPrompt(
            settings: settings,
            editing: editingContext,
            userText: text
        )
        // The mode is part of the system prompt, refreshed every turn so a
        // change applies to the next message rather than the next thread.
        let systemWithMode = system + AppPreferences.storedChatMode.instructions
        if let idx = messages.firstIndex(where: { $0.role == .system }) {
            messages[idx].text = systemWithMode
        } else {
            messages.insert(ChatMessage(role: .system, text: systemWithMode), at: 0)
        }
        // Pin full mini-app HTML into the conversation (hidden in UI) so the
        // model always sees it — even when OAuth trims the system prompt.
        ensureSourcePinned()
        // Local models struggle with long histories — keep a short window.
        // Recorded, not applied: the window shapes the REQUEST (see
        // `outgoing`), never the stored conversation.
        usesLocalHistoryWindow = LocalRuntimePolicy.isLocal(settings)
        // Everything from here on is the ACTIVE turn — `outgoing` must never
        // strip its tool scaffolding, only window the turns before it.
        turnStartIndex = messages.count
        messages.append(ChatMessage(role: .user, text: text))
        persist()
        busy = true
        AgentLiveActivityController.shared.start(prompt: text)

        // A new turn supersedes anything the previous one left behind: a stale
        // stop request (which the contract would otherwise weigh against this
        // turn's checkpoint) and the previous resume offer.
        AgentRunStopRequest.clear()
        interruptedTurn = nil
        turnInterruptedBySuspension = false
        turnStartedAt = Date()
        lastCheckpointAt = nil
        checkpointPendingTurn(force: true)
        // Protect the work NOW, not once the user happens to leave the app.
        BackgroundTurnGuard.shared.begin { [weak self] in
            self?.handleBackgroundTimeExpiring()
        }

        activeTask?.cancel()
        activeTask = Task { @MainActor in
            defer {
                BackgroundTurnGuard.shared.end()
                if !Task.isCancelled {
                    busy = false
                    statusLine = nil
                    // A turn that finished — well or badly — has nothing to
                    // resume. A turn iOS suspended does, and says so.
                    if !turnInterruptedBySuspension {
                        PendingTurnStore.clear()
                        interruptedTurn = nil
                    }
                    lastCheckpointAt = nil
                    persist()
                }
            }
            let runSettings = settings
            let apiKey = await AuthStore.effectiveKey(for: runSettings)
            if Task.isCancelled { return }
            if runSettings.preset.dialect != .mlx,
               runSettings.effectiveModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = String(localized: "Kein Modell gewählt — Mehr → KI-Anbieter → Modell aus der Liste wählen.")
                busy = false
                AgentLiveActivityController.shared.fail(message: errorMessage ?? String(localized: "Kein Modell"))
                return
            }
            if runSettings.preset.needsKey && apiKey.isEmpty && !ConnectionProbe.isLocalStyle(runSettings.presetId) {
                errorMessage = String(localized: "Kein API-Key / Abo-Login — unter KI-Anbieter ein Konto verbinden.")
                busy = false
                AgentLiveActivityController.shared.fail(message: errorMessage ?? "Kein Key")
                return
            }
            let provider = runSettings.makeProvider(apiKey: apiKey)
            // Plan mode withholds tools entirely rather than asking the model
            // not to use them — a prompt is a request, an empty list is a
            // guarantee. The lead chat is the only place `ask_agent` is offered.
            let mode = AppPreferences.storedChatMode
            let tools = mode.allowsTools
                ? await ToolRegistry.makeTools(settings: runSettings, apiKey: apiKey, delegating: true)
                : []
            await runTurn(provider: provider, tools: tools)
            if Task.isCancelled { return }
            // The activity already shows "Pausiert — App öffnen"; completing or
            // failing it here would overwrite the one truthful state there is.
            if turnInterruptedBySuspension { return }
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
            AgentLiveActivityController.shared.fail(message: String(localized: "Keine Antwort vom Modell — Modell/Abo prüfen und erneut senden."))
        }
    }

    /// Keep system + last few turns so 1–8B models don't lose the plot.
    /// Short history for an on-device / LAN model, which struggles with long
    /// context and — for MLX — pays for it in resident memory.
    ///
    /// **Pure.** This used to mutate `self.messages`, four lines before
    /// `persist()`. Switching a 40-message conversation to a local provider and
    /// sending one message therefore deleted the older 28 from disk: the
    /// truncated array was synced into the thread and written over
    /// chat-threads.json, with no quarantine copy and no way back — switching
    /// to a cloud provider again did not restore them. A request window has no
    /// business touching stored history, so this returns one instead.
    static func historyForLocal(_ history: [ChatMessage], maxMessages: Int = 12) -> [ChatMessage] {
        let system = history.filter { $0.role == .system }
        let pins = history.filter { isSourcePinMessage($0) }
        var rest = history.filter { $0.role != .system && !isSourcePinMessage($0) }
        // Drop tool scaffolding that confuses locals
        rest.removeAll { $0.role == .tool }
        for i in rest.indices where rest[i].role == .assistant {
            rest[i].toolCalls = []
        }
        if rest.count > maxMessages {
            rest = Array(rest.suffix(maxMessages))
        }
        // System → source pin → recent turns (pin must not be trimmed away).
        return system + pins.suffix(1) + rest
    }

    /// Whether this turn's REQUESTS should use the short local window. Set once
    /// per send from the resolved provider; never affects what is stored.
    private var usesLocalHistoryWindow = false

    /// Where the ACTIVE turn begins in `messages` — set by `send` right before
    /// it appends the user message. Everything from this index on is the turn
    /// currently running (user text, assistant tool calls, `tool` results,
    /// repair prompts).
    private var turnStartIndex = 0

    /// The message list to send, as opposed to the one we keep.
    ///
    /// The local window is applied to the PREVIOUS turns only. It strips tool
    /// scaffolding (`historyForLocal`), and stripping the active turn's too
    /// meant a local model with web tools enabled could never see a tool's
    /// result: the follow-up request lost the `tool` message, so the model
    /// re-issued the same call every round until the cap — a dead loop where
    /// a single web_search round used to work. (The pre-`outgoing` trim ran
    /// once per send, before the turn's messages existed, so it could not
    /// touch them; this split restores exactly that behavior.)
    private func outgoing(_ history: [ChatMessage]) -> [ChatMessage] {
        guard usesLocalHistoryWindow else { return history }
        let split = min(max(turnStartIndex, 0), history.count)
        return Self.historyForLocal(Array(history[..<split])) + Array(history[split...])
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

    /// Remove assistant tool calls that never received a matching `tool` result.
    /// An orphaned tool_use permanently breaks the thread on Anthropic, so this
    /// runs whenever a turn ends early (Stop, cancellation).
    func dropDanglingToolCalls() {
        let answered = Set(messages.compactMap { $0.role == .tool ? $0.toolCallId : nil })
        for index in messages.indices where messages[index].role == .assistant {
            let dangling = messages[index].toolCalls.filter { !answered.contains($0.id) }
            guard !dangling.isEmpty else { continue }
            messages[index].toolCalls.removeAll { !answered.contains($0.id) }
            if messages[index].toolCalls.isEmpty,
               messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               messages[index].mediaIds.isEmpty {
                messages.remove(at: index)
                return dropDanglingToolCalls()   // indices shifted — re-scan
            }
        }
    }

    /// Cancel the current generation (network stream / tool loop).
    ///
    /// STOP BEATS RESUME (see `TurnRestorePolicy`): stopping deletes the
    /// checkpoint, so nothing survives to be replayed — whether the stop came
    /// from the composer button or from the Live Activity.
    func stop() {
        activeTask?.cancel()
        activeTask = nil
        BackgroundTurnGuard.shared.end()
        busy = false
        statusLine = nil
        turnInterruptedBySuspension = false
        turnStartedAt = nil
        lastCheckpointAt = nil
        PendingTurnStore.clear()
        interruptedTurn = nil
        // The request has been served; leaving it set would cancel the NEXT
        // turn's checkpoint on the following foreground.
        AgentRunStopRequest.clear()
        // Cleared on EVERY exit, not only on a clean finish. It was previously
        // set in runGroupRound and cleared in one success path, so a stopped or
        // failed round left the conversation list showing "läuft…" forever —
        // and `switchTo` now reads this flag to tell a thread-safe group round
        // from an unsafe solo turn, so a stale value would be a correctness bug
        // rather than a cosmetic one.
        runningThreadId = nil
        ScreenWake.shared.setAgentBusy(false)
        AgentLiveActivityController.shared.cancel()
        if let last = messages.indices.last,
           messages[last].role == .assistant,
           messages[last].text.isEmpty,
           messages[last].toolCalls.isEmpty {
            messages.remove(at: last)
        }
        // Stopping mid-tool-loop can leave an assistant `tool_use` whose results
        // never arrived. Anthropic rejects that thread forever ("tool_use ids
        // found without tool_result"), so drop the dangling calls (and the whole
        // turn if it carried nothing else).
        dropDanglingToolCalls()
        errorMessage = nil
        statusLine = String(localized: "Gestoppt")
        persist()
        // Clear status after a beat so the chrome doesn't stay sticky.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if statusLine == String(localized: "Gestoppt") { statusLine = nil }
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
        // ORDER OF CHECKS IS THE CONTRACT: the persisted stop request is read
        // BEFORE any resume decision, so a turn the user cancelled from the
        // Lock Screen is discarded rather than replayed. See TurnRestorePolicy.
        evaluateInterruptedTurn()
        if busy {
            AgentLiveActivityController.shared.update(phase: statusLine ?? "Arbeitet weiter…")
        }
    }

    // MARK: - Stop from the Live Activity

    private func observeLiveActivityStopRequests() {
        stopRequestObserver = NotificationCenter.default.addObserver(
            forName: .aiityAgentStopRequested,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // `StopAgentRunIntent.perform()` runs in the app process but on an
            // arbitrary executor; `stop()` is @MainActor and touches
            // persistence, so the hop is mandatory.
            Task { @MainActor in self?.stopFromLiveActivity() }
        }
    }

    /// The Lock Screen / Dynamic Island Stop button reached a live process.
    func stopFromLiveActivity() {
        if busy {
            stop()   // clears the checkpoint and the flag itself
            return
        }
        // Nothing is running here — the turn was already killed by suspension
        // or the app was background-launched purely to run the intent. Honour
        // the request the same way: no replay, and a thread Anthropic will
        // still accept.
        AgentRunStopRequest.clear()
        PendingTurnStore.clear()
        interruptedTurn = nil
        dropDanglingToolCalls()
        persist()
    }

    // MARK: - Checkpoint / resume

    /// Write the small resume record for the running turn.
    ///
    /// Group rounds are deliberately excluded: each participant turn is already
    /// filed by thread id and persisted as it lands, and a `turnStartIndex`
    /// means nothing there — replaying one would re-run a whole round into a
    /// conversation the user may not even have open.
    private func checkpointPendingTurn(force: Bool = false) {
        guard !activeThreadIsGroup, let text = lastUserTextForRepair else { return }
        let now = Date()
        if !force, let last = lastCheckpointAt, now.timeIntervalSince(last) < Self.checkpointInterval {
            return
        }
        lastCheckpointAt = now
        let partial = messages.last(where: { $0.role == .assistant })?.text ?? ""
        PendingTurnStore.save(
            PendingTurn(
                threadId: activeThreadId,
                userText: text,
                turnStartIndex: turnStartIndex,
                repairPasses: repairPassesThisTurn,
                startedAt: turnStartedAt ?? now,
                updatedAt: now,
                partialAssistantText: partial
            )
        )
    }

    /// iOS is about to take the background grant back.
    ///
    /// Order matters and is pinned by test: **checkpoint → notify → cancel →
    /// repair the thread → truthful Live Activity**, and only then does
    /// `BackgroundTurnGuard` hand the grant back. Checkpointing first is the
    /// point — everything after it may be cut short, and the checkpoint is
    /// what makes that survivable. The notification goes out before the cancel
    /// because cancelling can take the main actor away for a moment.
    func handleBackgroundTimeExpiring() {
        #if DEBUG
        expirationSteps = []
        #endif
        guard busy else { return }
        step("checkpoint")
        checkpointPendingTurn(force: true)

        step("notify")
        // Gated: posts only when authorization already exists. NEVER requests
        // it — this is a background path (see AgentBackgroundNotifier).
        AgentBackgroundNotifier.notifyTurnPaused()

        step("cancel")
        turnInterruptedBySuspension = true
        activeTask?.cancel()
        activeTask = nil

        step("repair")
        busy = false
        runningThreadId = nil
        statusLine = nil
        // A turn cut mid-loop can leave an assistant `tool_use` whose result
        // never arrived; Anthropic rejects that thread forever.
        dropDanglingToolCalls()
        persist()
        interruptedTurn = PendingTurnStore.load()

        step("liveActivityPaused")
        AgentLiveActivityController.shared.markPausedForExpiredBackgroundTime()
    }

    private func step(_ name: String) {
        #if DEBUG
        expirationSteps.append(name)
        #endif
    }

    /// Shared tail of the "the stream died because we were suspended" branch.
    private func noteSuspensionInterrupted(partialIndex: Int) {
        turnInterruptedBySuspension = true
        // Checkpoint BEFORE dropping an empty assistant message, so whatever
        // did stream in is captured.
        checkpointPendingTurn(force: true)
        if partialIndex < messages.count,
           messages[partialIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           messages[partialIndex].mediaIds.isEmpty,
           messages[partialIndex].toolCalls.isEmpty {
            messages.remove(at: partialIndex)
        }
        dropDanglingToolCalls()
        // No NetworkErrorFriendly banner: nothing is broken, the app was asleep.
        errorMessage = nil
        statusLine = nil
        persist()
        interruptedTurn = PendingTurnStore.load()
        AgentLiveActivityController.shared.markPausedForExpiredBackgroundTime()
    }

    /// Apply the stop-vs-resume contract. Called on cold launch and on every
    /// foreground.
    func evaluateInterruptedTurn(now: Date = Date()) {
        let decision = TurnRestorePolicy.decide(
            stopRequestedAt: AgentRunStopRequest.pendingDate(),
            pending: PendingTurnStore.load(),
            now: now
        )
        switch decision {
        case .none:
            AgentRunStopRequest.clear()
            guard !busy else { return }
            PendingTurnStore.clear()
            interruptedTurn = nil

        case .discardCancelledTurn:
            // The user pressed Stop somewhere this process could not hear it.
            AgentRunStopRequest.clear()
            PendingTurnStore.clear()
            interruptedTurn = nil
            if busy {
                stop()
            } else {
                dropDanglingToolCalls()
                persist()
            }

        case .offerResume(let pending):
            AgentRunStopRequest.clear()
            // A turn still running in THIS process needs no offer — its own
            // checkpoint is simply the live one.
            guard !busy else { return }
            interruptedTurn = pending
        }
    }

    /// The user declined the resume offer.
    func dismissInterruptedTurn() {
        interruptedTurn = nil
        PendingTurnStore.clear()
    }

    /// Rewind the conversation to the start of an interrupted turn.
    ///
    /// Split out of `resumeInterruptedTurn` so the rewind is testable without a
    /// provider, a key or a network. Returns the user text to re-send, or nil
    /// when the checkpoint no longer fits the stored conversation.
    ///
    /// Replay, not resume: no provider can continue a half-finished stream, so
    /// the honest primitive is to delete everything from `turnStartIndex` on
    /// and send the same message again. The checkpointed partial answer is
    /// therefore discarded here by design.
    @discardableResult
    func rewindToInterruptedTurnStart(_ pending: PendingTurn) -> String? {
        if activeThreadId != pending.threadId {
            switchTo(threadId: pending.threadId)
            guard activeThreadId == pending.threadId else { return nil }
        }
        guard pending.turnStartIndex >= 0, pending.turnStartIndex <= messages.count else { return nil }
        if pending.turnStartIndex < messages.count {
            messages.removeSubrange(pending.turnStartIndex...)
        }
        dropDanglingToolCalls()
        persist()
        return pending.userText
    }

    /// Replay the interrupted turn. A tap, never automatic: an unattended
    /// replay re-spends the user's own tokens on a request that may well have
    /// completed server-side.
    func resumeInterruptedTurn(settings: ProviderSettings) {
        guard !busy, let pending = interruptedTurn else { return }
        interruptedTurn = nil
        PendingTurnStore.clear()
        guard let text = rewindToInterruptedTurnStart(pending) else { return }
        errorMessage = nil
        send(text, settings: settings)
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
                statusLine = wantsApp ? "Baut Mini-App…" : String(localized: "Schließt ab…")
            } else {
                statusLine = String(localized: "Schreibt…")
            }

            messages.append(ChatMessage(role: .assistant, text: ""))
            let assistantIndex = messages.count - 1
            var requestedCalls: [ToolCallData] = []
            AgentLiveActivityController.shared.update(phase: statusLine, progress: 0.25 + Double(round) * 0.1)

            do {
                var charBudget = 0
                for try await event in provider.streamChat(messages: outgoing(Array(messages[..<assistantIndex])), tools: specs) {
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
                                phase: statusLine ?? String(localized: "Schreibt…"),
                                detail: preview.isEmpty ? nil : preview,
                                progress: nil
                            )
                            // Live mini-app draft while HTML streams (don’t wait for fence close).
                            maybePublishStreamingDraft(from: messages[assistantIndex].text)
                            // Piggy-backs on the existing 200-char budget and
                            // is itself time-throttled, so a long HTML stream
                            // writes a few KB every couple of seconds rather
                            // than on every delta.
                            checkpointPendingTurn()
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
                // A socket that froze because iOS suspended the process throws
                // the same URLError a broken network does. It is not a fault,
                // and the scary banner is the wrong answer: checkpoint what
                // arrived, offer a replay, and keep the card honest.
                if TurnInterruptionPolicy.isBackgroundInterruption(
                    error: error,
                    wasBackgrounded: AgentLiveActivityController.shared.backgroundedDuringTurn
                ) {
                    noteSuspensionInterrupted(partialIndex: assistantIndex)
                    return
                }
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
                            errorMessage = friendly + String(localized: " — unvollständige Mini-App gerettet, bitte prüfen.")
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
                // Stop must take effect between tools: tool runs swallow their own
                // errors (incl. URLError.cancelled), so without these checks a
                // cancelled turn keeps running tools and appends messages after the
                // UI already tore the turn down.
                if Task.isCancelled { return }
                statusLine = Self.statusText(for: call)
                AgentLiveActivityController.shared.update(
                    phase: statusLine,
                    detail: Self.statusDetail(for: call),
                    progress: nil
                )
                let result = await toolsByName[call.name]?.run(argumentsJSON: call.argumentsJSON)
                    ?? ToolRunResult("Error: unknown tool \(call.name)")
                // Record the result even when cancelled: the work is already paid
                // for, and the tool_result must exist to pair with its tool_use.
                pendingMediaIds.append(contentsOf: result.mediaIds)
                messages.append(ChatMessage(role: .tool, text: result.text, toolCallId: call.id, toolName: call.name))
                // Tool boundary: the cheapest, most valuable checkpoint there
                // is — the round's expensive work is now paired and safe.
                checkpointPendingTurn(force: true)
                if Task.isCancelled {
                    if let last = messages.indices.last, !result.mediaIds.isEmpty {
                        messages[last].mediaIds = result.mediaIds   // keep generated media visible
                    }
                    persist()
                    return
                }
            }
            statusLine = String(localized: "Schreibt…")
            AgentLiveActivityController.shared.update(phase: String(localized: "Schreibt…"), progress: 0.55)
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
            for try await event in provider.streamChat(messages: outgoing(Array(messages[..<assistantIndex])), tools: []) {
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
            errorMessage = String(localized: "Antwort unvollständig — bitte erneut senden (kürzere Anfrage hilft).")
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
        if statusLine == String(localized: "Schreibt…") || statusLine == nil {
            statusLine = String(localized: "Mini-App wird gebaut…")
        }
    }

    /// Validate mini-app HTML (multi-file aware); if broken, one repair turn (no tools).
    private func handleAssistantFinished(provider: LLMProvider, tools: [AgentTool], assistantIndex: Int) async {
        // Drop a fully-empty assistant turn (no text, no media, no tool calls).
        // Keeping it poisons the thread — Anthropic 400s on empty assistant content
        // on the next request — and shows a blank bubble.
        if assistantIndex < messages.count,
           messages[assistantIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           messages[assistantIndex].mediaIds.isEmpty,
           messages[assistantIndex].toolCalls.isEmpty {
            messages.remove(at: assistantIndex)
            statusLine = nil
            persist()
            return
        }
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
                // Follow-up edits must build on THIS version, not the original.
                // The pin used to refresh only on "Behalten", so a user who said
                // "still not right" without keeping got the model editing the
                // old source again — it discussed a fix and produced the same
                // app, which reads as having done nothing.
                if editingContext != nil {
                    updateEditingSource(html: runnable, name: bundle.name)
                }
                Analytics.track("miniapp_draft", ["multi": bundle.isMultiFile ? "1" : "0"])
                if !validation.issues.isEmpty {
                    lastMiniAppWarnings = validation.issues
                    // Soft banner — does not block keep/preview.
                    errorMessage = String(localized: "Mini-App bereit (Hinweise: ") + validation.issues.prefix(2).joined(separator: "; ") + ")"
                }
                // Keep fixing while the mode allows it. Auto keeps going until
                // the app validates or the budget runs out; the other modes get
                // one pass, and only for an obviously-truncated document.
                let mode = AppPreferences.storedChatMode
                if !validation.isValid,
                   repairPassesThisTurn < mode.maxRepairPasses,
                   runnable.count < 200 || mode.repairsCompleteApps {
                    repairPassesThisTurn += 1
                    statusLine = mode.maxRepairPasses > 1
                        ? "Korrigiert Mini-App (\(repairPassesThisTurn)/\(mode.maxRepairPasses))…"
                        : String(localized: "Korrigiert Mini-App…")
                    AgentLiveActivityController.shared.update(phase: String(localized: "Korrigiert Mini-App…"), progress: 0.75)
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
            if repairPassesThisTurn >= AppPreferences.storedChatMode.maxRepairPasses {
                draftMiniApp = draft
                // Say the budget ran out rather than implying the app is fine.
                errorMessage = String(localized: "Mini-App-Prüfung nach \(repairPassesThisTurn) Versuchen: ")
                    + validation.issues.joined(separator: "; ")
                return
            }
            repairPassesThisTurn += 1
            statusLine = String(localized: "Korrigiert Mini-App…")
            AgentLiveActivityController.shared.update(phase: String(localized: "Korrigiert Mini-App…"), progress: 0.75)
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
        case AskAgentTool.toolName: return "Fragt Agent…"
        default: return "Tool: \(call.name)"
        }
    }

    private static func statusDetail(for call: ToolCallData) -> String {
        let arguments = toolArguments(call.argumentsJSON)
        switch call.name {
        case "web_search": return arguments["query"] as? String ?? ""
        case "fetch_url": return arguments["url"] as? String ?? ""
        case "generate_image":
            return String((arguments["prompt"] as? String ?? "").prefix(60))
        case AskAgentTool.toolName:
            return arguments["agent"] as? String ?? ""
        default: return call.name
        }
    }

    // MARK: - Threads

    @discardableResult
    func newThread(participantAgentIds: [UUID] = [], title: String = "") -> UUID? {
        guard !busy else { return nil }
        syncActiveIntoThreads()
        var thread = ChatThread()
        thread.participantAgentIds = participantAgentIds
        thread.title = title
        threads.insert(thread, at: 0)
        activeThreadId = thread.id
        loadActiveThread()
        persist()
        return thread.id
    }

    // MARK: - Group conversations

    /// Participants of the open thread, resolved against the agent store.
    var activeParticipants: [AgentDefinition] { participants(inThread: activeThreadId) }

    /// Participants of a NAMED thread. A discussion that runs several rounds
    /// must keep asking the roster it began with, even if the user has since
    /// opened a different conversation.
    func participants(inThread threadId: UUID) -> [AgentDefinition] {
        let ids = threads.first(where: { $0.id == threadId })?.participantAgentIds ?? []
        guard !ids.isEmpty else { return [] }
        // `active()`, not `load()`: a switched-off agent must not speak in a
        // group either — the toggle meant nothing here before.
        let available = AgentStore.active()
        // Preserve the order the user picked them in.
        return ids.compactMap { id in available.first { $0.id == id } }
    }

    /// Post the user's message, then let every participant speak once.
    private func sendToGroup(_ text: String, settings: ProviderSettings) {
        messages.append(ChatMessage(role: .user, text: text))
        groupRoundsThisTurn = 0
        persist()
        // The group branch returns before send()'s own start(), so without this
        // a group conversation ran with no Live Activity at all — no Dynamic
        // Island, nothing on the Lock Screen while the agents worked.
        AgentLiveActivityController.shared.start(prompt: text)
        runGroupRound(settings: settings)
    }

    /// Another round of the same discussion, without a new user message. This
    /// is user-driven on purpose: the agents never decide to keep going by
    /// themselves.
    func continueGroupDiscussion(settings: ProviderSettings) {
        guard !busy, activeThreadIsGroup, !messages.isEmpty else { return }
        // A manual round is its own budget, not a continuation of the last one.
        groupRoundsThisTurn = 0
        runGroupRound(settings: settings)
    }

    /// Group rounds already run for the current user message.
    private var groupRoundsThisTurn = 0

    /// - Parameter threadId: the conversation this discussion belongs to.
    ///   Passed explicitly for rounds 2+ because by then the user may have
    ///   opened a different conversation, and re-deriving it from
    ///   `activeThreadId` sent the next round into whatever was on screen — a
    ///   solo chat would resolve to zero participants and show "Keine aktiven
    ///   Agenten in dieser Gruppe" in a conversation that never had any.
    private func runGroupRound(settings: ProviderSettings, threadId: UUID? = nil) {
        // The round belongs to the thread it STARTED on. The user may now open
        // another conversation while it runs, so every turn is filed by id —
        // appending to `messages` would drop them into whatever is on screen.
        let roundThreadId = threadId ?? activeThreadId
        let participants = participants(inThread: roundThreadId)
        #if DEBUG
        print("AIITY-GROUP ids=\(activeParticipantIds.count) resolved=\(participants.count) names=\(participants.map(\.name))")
        #endif
        guard !participants.isEmpty else {
            // Reachable whenever every member was deleted or switched off; the
            // user's message is already in the thread, so failing silently would
            // look like the app ignored them.
            errorMessage = String(localized: "Keine aktiven Agenten in dieser Gruppe — im Tab „Agenten“ anlegen oder wieder einschalten.")
            busy = false
            // Reachable from the auto-continue recursion with the marker
            // already set; leaving it pins a "läuft…" spinner on a thread that
            // is idle.
            runningThreadId = nil
            statusLine = nil
            AgentLiveActivityController.shared.fail(message: String(localized: "Keine aktiven Agenten"))
            return
        }
        busy = true
        runningThreadId = roundThreadId
        statusLine = nil
        ScreenWake.shared.setAgentBusy(true)
        // Same protection a solo turn gets. No checkpoint is written for a
        // group round (see `checkpointPendingTurn`) — each participant's turn
        // is already filed by thread id and persisted as it lands — but the
        // round still deserves the full grant, the pause notification and a
        // truthful "Pausiert" card instead of a frozen one. Released by
        // complete() / fail() / stop() on every exit from the round.
        BackgroundTurnGuard.shared.begin { [weak self] in
            self?.handleBackgroundTimeExpiring()
        }
        DiagnosticsRecorder.shared.record(
            "gruppe",
            "Runde \(groupRoundsThisTurn + 1) · \(participants.count) Teilnehmer"
                + String(localized: " · \(self.messages.count) Nachrichten im Verlauf")
        )

        activeTask = Task { [weak self] in
            guard let self else { return }
            let transcript = self.messages
            // Backstop only. Releasing the model on each warning is what
            // actually keeps the app alive, and on device a healthy three-agent
            // local round produced six warnings and finished — so stopping on
            // one would abort nearly every local round. This threshold is far
            // above that: it catches a round whose memory never comes back.
            let roundStarted = Date()
            let usesLocalModel = participants.contains {
                $0.settings(fallback: settings).preset.dialect == .mlx
            }
            await GroupChatRunner.runRound(
                agents: participants,
                transcript: transcript,
                chatSettings: settings,
                isCancelled: {
                    if Task.isCancelled { return true }
                    guard usesLocalModel else { return false }
                    return MemoryPressure.shared.warnings(since: roundStarted)
                        >= GroupChatRunner.memoryWarningAbortThreshold
                },
                onStart: { agent in
                    Task { @MainActor in
                        let phase = "\(agent.emoji) \(agent.name) schreibt…"
                        self.statusLine = phase
                        AgentLiveActivityController.shared.update(phase: phase, progress: 0.5)
                    }
                },
                onTurn: { turn in
                    Task { @MainActor in
                        let message = ChatMessage(
                            role: .assistant,
                            text: turn.text,
                            authorName: turn.agent.name,
                            authorEmoji: turn.agent.emoji
                        )
                        self.append(message, toThread: roundThreadId)
                        // Group turns were never checked for a mini-app, so a
                        // group could discuss one at length and never actually
                        // hand one over. Any agent that emits a complete fence
                        // now produces the same draft card as a normal chat.
                        if self.activeThreadId == roundThreadId,
                           let bundle = MiniAppBundleParser.extract(from: turn.text) {
                            let runnable = MiniAppValidator.prepareHTML(bundle.bundledHTML())
                            if runnable.count >= 80 {
                                self.draftMiniApp = MiniAppDraft(
                                    name: bundle.name,
                                    emoji: bundle.emoji,
                                    html: runnable,
                                    filesJSON: bundle.filesJSON(),
                                    iconSymbol: bundle.iconSymbol
                                )
                            }
                        }
                        self.persistPublic()
                    }
                }
            )
            await MainActor.run {
                // Only the round that is still the active task may clear `busy`.
                // A cancelled round's teardown otherwise unlocks the session
                // while its replacement is mid-flight, letting two rounds append
                // to the same thread at once.
                guard !Task.isCancelled else {
                    self.persistPublic()
                    return
                }
                // Stopped short to stay alive. Say so — silently producing half
                // a round reads as the agents losing interest.
                if usesLocalModel,
                   MemoryPressure.shared.warnings(since: roundStarted)
                       >= GroupChatRunner.memoryWarningAbortThreshold {
                    self.errorMessage = String(localized: "Runde gestoppt: dem Gerät ging der Speicher aus. ")
                        + String(localized: "Ein kleineres lokales Modell wählen, oder für Gruppen einen Cloud-Anbieter.")
                    self.busy = false
                    self.runningThreadId = nil
                    self.statusLine = nil
                    ScreenWake.shared.setAgentBusy(false)
                    AgentLiveActivityController.shared.fail(message: String(localized: "Zu wenig Speicher"))
                    self.persistPublic()
                    return
                }
                self.groupRoundsThisTurn += 1
                self.persistPublic()

                // Auto keeps the discussion going by itself rather than making
                // the user tap for each round — still bounded.
                let mode = AppPreferences.storedChatMode
                if self.groupRoundsThisTurn < mode.automaticGroupRounds {
                    self.runGroupRound(settings: settings, threadId: roundThreadId)
                    return
                }
                self.busy = false
                self.runningThreadId = nil
                self.statusLine = nil
                ScreenWake.shared.setAgentBusy(false)
                AgentLiveActivityController.shared.complete(
                    summary: "\(participants.count) Agenten, \(self.groupRoundsThisTurn) Runden"
                )
            }
        }
    }

    /// File a message into a specific thread, whether or not it is on screen.
    /// A background round must not write into the conversation the user has
    /// since opened.
    private func append(_ message: ChatMessage, toThread id: UUID) {
        if activeThreadId == id {
            messages.append(message)
            return
        }
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].messages.append(message)
        threads[index].updatedAt = .now
    }

    /// Thread a round is currently running in, so the list can show it.
    @Published private(set) var runningThreadId: UUID?

    /// Open a conversation from the list: make it active and drive the push.
    func open(threadId: UUID) {
        switchTo(threadId: threadId)
        // Push only what we actually switched to. `switchTo` can decline (an
        // unknown id), and pushing regardless would show the CURRENT
        // conversation under the tapped row's identity — the user reads
        // someone else's chat.
        guard activeThreadId == threadId else { return }
        openThreadId = threadId
    }

    /// Agents taking part in the open conversation (empty for a normal chat).
    var activeParticipantIds: [UUID] {
        threads.first(where: { $0.id == activeThreadId })?.participantAgentIds ?? []
    }

    var activeThreadIsGroup: Bool { !activeParticipantIds.isEmpty }

    func switchTo(threadId: UUID) {
        guard threadId != activeThreadId else { return }
        guard threads.contains(where: { $0.id == threadId }) else { return }

        // A GROUP round survives the switch, which is the whole point of
        // allowing one: it captured its thread id up front and files every turn
        // through `append(_:toThread:)`, so it never touches `messages`.
        //
        // A SOLO turn does not. `runTurn` holds a raw `assistantIndex` into
        // `messages` across the streaming await, and `loadActiveThread()` below
        // replaces that array wholesale. Letting it run past the switch means
        // one of two things on the next token: a shorter target thread traps on
        // `messages[assistantIndex]` — an outright crash — and a longer one
        // appends this conversation's answer into the middle of the other
        // conversation, which `persist()` then writes to disk.
        //
        // Relaxing the old `guard !busy` was right for groups and wrong for
        // solo turns; this draws the line where the safety actually differs.
        if busy, runningThreadId == nil {
            stop()
        }
        DiagnosticsRecorder.shared.record(
            "chat", "Unterhaltung gewechselt\(busy ? " — während ein Lauf aktiv ist" : "")"
        )
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
        reclaimMedia()   // free images/videos the deleted thread referenced
        persist()
    }

    var activeThreadTitle: String {
        threads.first(where: { $0.id == activeThreadId })?.title ?? ""
    }

    /// Entry point from the library / mini-app sheet: continue a saved mini-app.
    func startEditing(id: UUID, name: String, html: String) {
        // `newThread()` returns nil while a turn is running. Ignoring that and
        // assigning `messages` below replaced the LIVE conversation instead of
        // a fresh one — destroying it on disk via persist(), and leaving the
        // in-flight turn indexing into an array that no longer has its slot.
        guard newThread() != nil else {
            errorMessage = String(localized: "Es läuft gerade eine Antwort — bitte kurz warten oder stoppen.")
            return
        }
        editingContext = EditingContext(id: id, name: name, html: html)
        messages = [
            ChatMessage(
                role: .assistant,
                text: String(localized: "Du bearbeitest **\(name)**. Der aktuelle Quellcode ist an die KI übergeben — beschreib nur, was ich ändern oder verbessern soll (Design, Features, Icon, Netzwerk …).")
            ),
        ]
        ensureSourcePinned()
        draftMiniApp = nil
        chatPresented = true
        persist()
    }

    /// Preview / unsaved draft → new edit thread (keep will insert a new app).
    func startEditingDraft(name: String, html: String, emoji: String = "✨") {
        guard newThread() != nil else {
            errorMessage = String(localized: "Es läuft gerade eine Antwort — bitte kurz warten oder stoppen.")
            return
        }
        editingContext = EditingContext(id: UUID(), name: name, html: html)
        messages = [
            ChatMessage(
                role: .assistant,
                text: String(localized: "Vorschau von **\(name)** \(emoji). Quellcode ist an die KI übergeben — sag, was ich anpassen soll; danach speichern wir die neue Version.")
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
        refreshEmptyStateSuggestions()
    }

    // MARK: - Empty-state suggestions

    /// Recomposes the empty-state chips for the ACTIVE thread.
    ///
    /// Called from `loadActiveThread()` — which every entry point funnels
    /// through (new chat, switch, delete, restore) — and from
    /// `refreshSmartSuggestions` with `force` when model ideas arrive or
    /// disappear. Never from a view body: it publishes.
    private func refreshEmptyStateSuggestions(force: Bool = false) {
        let threadId = activeThreadId
        let threadChanged = lastSuggestionThreadId != threadId
        guard threadChanged || force || emptyStateSuggestions.isEmpty else { return }
        // Only a real thread change advances the no-repeat memory; a forced
        // recompose within the same conversation keeps the same exclusion set,
        // so arriving model ideas prepend instead of re-dealing the whole row.
        if threadChanged, !emptyStateSuggestions.isEmpty {
            previousSuggestionSet = Set(emptyStateSuggestions)
        }
        emptyStateSuggestions = ChatSuggestions.compose(
            modelSuggestions: modelSuggestions,
            seed: suggestionSeed,
            excluding: previousSuggestionSet
        )
        lastSuggestionThreadId = threadId
    }

    private var suggestionSeed: UInt64 {
        #if DEBUG
        if let override = suggestionSeedOverride { return override }
        #endif
        return ChatSuggestions.seed(for: activeThreadId)
    }

    /// Optional model-generated ideas for the empty state. Silent by design:
    /// ineligible, offline, throttled or unparsable all end up here as "no
    /// model ideas", which simply leaves the curated chips in place.
    ///
    /// `savedAppCount` is bucketed inside the service — no name, no chat
    /// content and no title ever leaves the device.
    func refreshSmartSuggestions(settings: ProviderSettings, savedAppCount: Int) async {
        let generated = await ChatSuggestionService.suggestions(
            for: settings, savedAppCount: savedAppCount
        ) ?? []
        guard generated != modelSuggestions else { return }
        modelSuggestions = generated
        refreshEmptyStateSuggestions(force: true)
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
        let contentChanged = thread.messages != messages
        thread.messages = messages
        thread.editingContext = editingContext
        // Only real activity reorders the list. Bumping on every persist meant
        // simply OPENING a conversation moved it to the top, so the list showed
        // "recently viewed" while claiming to show recent messages.
        if !messages.isEmpty, contentChanged { thread.updatedAt = .now }
        if thread.title.isEmpty {
            if let context = editingContext {
                thread.title = String(localized: "✏️ \(context.name)")
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

    #if DEBUG
    /// Put the session into the state a running GROUP round leaves it in.
    /// `switchTo` distinguishes that from a solo turn, and the difference
    /// decides whether the in-flight work is stopped — worth testing without
    /// standing up a provider, a network and an agent roster.
    var activeThreadIdForTesting: UUID { activeThreadId }

    /// Pins the empty-state sample so tests (and the screenshot runs, via
    /// AIITY_SUGGESTION_SEED) see a known set instead of a per-thread one.
    var suggestionSeedOverride: UInt64? = ProcessInfo.processInfo
        .environment["AIITY_SUGGESTION_SEED"].flatMap { UInt64($0) }

    /// Injects what the provider would have proposed, without a provider.
    func setModelSuggestionsForTesting(_ items: [String]) {
        modelSuggestions = items
        refreshEmptyStateSuggestions(force: true)
    }

    func beginGroupRoundForTesting(threadId: UUID) {
        busy = true
        runningThreadId = threadId
    }

    /// Puts the session into the state `send()` leaves it in, without a
    /// provider, a key or a network — so the checkpoint / expiration /
    /// stop-vs-resume paths can be driven directly.
    func beginTurnForTesting(userText: String, turnStartIndex: Int, startedAt: Date = Date()) {
        lastUserTextForRepair = userText
        self.turnStartIndex = turnStartIndex
        turnStartedAt = startedAt
        lastCheckpointAt = nil
        turnInterruptedBySuspension = false
        busy = true
    }

    func checkpointPendingTurnForTesting() { checkpointPendingTurn(force: true) }
    #endif

    /// Re-read the archive from disk, discarding in-memory state.
    ///
    /// Needed after a backup import: the import writes `chat-threads.json`
    /// underneath a session that was constructed at launch and still holds its
    /// own (usually empty) threads. Without this the very next persist() — one
    /// tap on "Neuer Chat" — writes that stale state straight over everything
    /// just restored, and because the file is then non-empty a second import
    /// silently declines to write at all.
    func reloadFromDisk() {
        guard !busy else { return }
        restore()
        openThreadId = nil
    }

    /// Drop threads that hold no real content (newThread/startEditing can leave
    /// these behind). Deliberately does NOT cap or delete conversations that have
    /// messages: silently destroying history the user never agreed to lose is
    /// worse than an large store, and there is now an export path for size.
    private func pruneThreads() {
        let before = threads.map(\.id)
        threads.removeAll { thread in
            thread.id != activeThreadId && thread.messages.allSatisfy { $0.role == .system }
        }
        if threads.map(\.id) != before { reclaimMedia() }
    }

    /// Delete stored media no longer referenced by any thread or the live messages.
    private func reclaimMedia() {
        // Never sweep while a turn is running: media it generated is not attached
        // to a message yet (MediaStore's grace window is a second safety net).
        guard !busy else { return }
        var ids = Set<String>()
        for thread in threads { for message in thread.messages { ids.formUnion(message.mediaIds) } }
        for message in messages { ids.formUnion(message.mediaIds) }
        MediaStore.sweep(keeping: ids)
    }

    private func persist() {
        // Hard stop: an archive we failed to read AND failed to copy is still
        // the only copy there is. Writing anything over it is the loss.
        guard persistDisabledReason == nil else { return }
        syncActiveIntoThreads()
        pruneThreads()
        let snapshot = Snapshot(threads: threads, activeThreadId: activeThreadId)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }

    private func restore() {
        let stored = try? Data(contentsOf: Self.storeURL)
        if let stored,
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: stored),
           !snapshot.threads.isEmpty {
            threads = snapshot.threads
            activeThreadId = snapshot.threads.contains(where: { $0.id == snapshot.activeThreadId })
                ? snapshot.activeThreadId
                : snapshot.threads[0].id
            loadActiveThread()
            return
        }

        // The file EXISTS but would not decode. Starting fresh here is what
        // destroys a history: the very next persist() writes an empty snapshot
        // over it. Keep the bytes under a timestamped name first, so a bad
        // decode costs a restart instead of every conversation.
        if let stored, stored.count > 1, !quarantineChatStore(stored) {
            // The bytes could not be copied aside, so the unreadable file is
            // still the only copy of the user's history. Starting fresh and
            // saving would overwrite it — a few hundred bytes fit where the
            // multi-megabyte copy did not. Come up empty and refuse to write
            // instead, so a restart or freeing some space can still recover it.
            persistDisabledReason = String(localized: "Der Chat-Verlauf konnte weder gelesen noch gesichert werden ")
                + String(localized: "(vermutlich zu wenig Speicherplatz). Es wird nichts geschrieben, damit die Datei ")
                + String(localized: "erhalten bleibt — bitte Speicher freigeben und die App neu starten.")
            errorMessage = persistDisabledReason
            DiagnosticsRecorder.shared.record("chat", String(localized: "Archiv unlesbar UND nicht sicherbar — Schreiben gesperrt"))
            let placeholder = ChatThread()
            threads = [placeholder]
            activeThreadId = placeholder.id
            loadActiveThread()
            return
        }

        if let data = try? Data(contentsOf: Self.legacyStoreURL),
           let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data),
           !legacy.messages.isEmpty {
            var thread = ChatThread(messages: legacy.messages, editingContext: legacy.editingContext)
            if let firstUser = legacy.messages.first(where: { $0.role == .user }) {
                thread.title = String(firstUser.text.prefix(48))
            }
            threads = [thread]
            activeThreadId = thread.id
            loadActiveThread()
            // Save the migrated copy BEFORE dropping the source. Deleting first
            // means a crash in between loses both the old file and the new one.
            persist()
            if FileManager.default.fileExists(atPath: Self.storeURL.path) {
                try? FileManager.default.removeItem(at: Self.legacyStoreURL)
            }
            return
        }

        let fresh = ChatThread()
        threads = [fresh]
        activeThreadId = fresh.id
        loadActiveThread()
    }

    /// Move an undecodable chat archive aside instead of letting it be
    /// overwritten. Named with a timestamp so repeated failures do not
    /// overwrite each other's evidence.
    /// Move an undecodable archive aside. Returns false when the copy failed,
    /// in which case the original is still the only copy in existence.
    ///
    /// This used to return Void, so its own comment — "do NOT continue" — was
    /// unenforceable: `restore()` carried on to `threads = [ChatThread()]`, and
    /// the next persist() wrote a few hundred bytes of empty snapshot over a
    /// multi-megabyte archive that had just failed to be copied. The condition
    /// that makes the copy fail is a nearly full disk, which is also a
    /// plausible cause of the bad file — so the two coincide by nature rather
    /// than by bad luck.
    @discardableResult
    private func quarantineChatStore(_ data: Data) -> Bool {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = Self.storeURL.deletingLastPathComponent()
            .appendingPathComponent("chat-threads.json.corrupt-\(stamp)")
        guard (try? data.write(to: target, options: .atomic)) != nil else {
            return false
        }
        try? FileManager.default.removeItem(at: Self.storeURL)
        return true
    }

    /// Set when an archive could not be read AND could not be copied aside.
    /// While true nothing may be written, or the unreadable-but-present file
    /// is destroyed by the first save.
    private(set) var persistDisabledReason: String?
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
