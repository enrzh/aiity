import Foundation
import AppIntents

// MARK: - Target membership
//
// Unlike `StopAgentRunIntent`, nothing in this file is a `LiveActivityIntent`,
// so it belongs to the APP TARGET ONLY. It is covered by project.yml's
// `sources: - path: AIApp` and must NOT be added to `AIAppLiveActivity`:
// these intents reach `IntentRouter`, `AgentStore` and the mini-app index, none
// of which exist in the widget process, and a second copy of an `AppEntity`
// type in an extension binary makes App Intents metadata ambiguous.
//
// The build-time proof that this file is wired up at all is the extracted
// metadata: `AIApp.app/Metadata.appintents/` must exist in the built product.
// Missing metadata is the classic silent failure — the app compiles, the code
// is right, and no shortcut ever appears in the Shortcuts app.

// MARK: - Mini-apps as an entity

/// One of the user's saved mini-apps, as Shortcuts and Siri see it.
struct MiniAppEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Mini-App",
        numericFormat: "\(placeholder: .int) Mini-Apps"
    )
    static var defaultQuery = MiniAppEntityQuery()

    var id: UUID
    var name: String
    var symbol: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            image: .init(systemName: symbol ?? "square.grid.2x2")
        )
    }

    init(_ entry: MiniAppIndex.Entry) {
        id = entry.id
        name = entry.name.isEmpty ? String(localized: "Mini-App") : entry.name
        symbol = entry.symbol
    }
}

/// Backed by `MiniAppIndex`, never by the SwiftData store — see the long note
/// there for why. Deliberately `nonisolated`: the whole query is a small file
/// read plus a pure string filter, so it must not hop to the main actor (which
/// on a background launch may be busy building the whole UI).
struct MiniAppEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [MiniAppEntity] {
        let wanted = Set(identifiers)
        return MiniAppIndex.load()
            .filter { wanted.contains($0.id) }
            .map(MiniAppEntity.init)
    }

    func entities(matching string: String) async throws -> [MiniAppEntity] {
        IntentNameMatch
            .filter(MiniAppIndex.load(), query: string, name: \.name)
            .map(MiniAppEntity.init)
    }

    func suggestedEntities() async throws -> [MiniAppEntity] {
        MiniAppIndex.load().map(MiniAppEntity.init)
    }
}

// MARK: - Agents as an entity

/// One configured worker agent. Only **enabled** agents are offered: a
/// switched-off agent is not allowed to speak in a conversation
/// (`ChatSession.participants(inThread:)` filters on `AgentStore.active()`), so
/// offering one in Siri would promise a reply that never comes.
struct AgentEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Agent",
        numericFormat: "\(placeholder: .int) Agenten"
    )
    static var defaultQuery = AgentEntityQuery()

    var id: UUID
    var name: String
    var role: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(role)")
    }

    init(_ agent: AgentDefinition) {
        id = agent.id
        name = agent.name
        role = agent.role
    }
}

/// `AgentStore.active()` is `nonisolated` precisely so this can run off the
/// main actor: it is a decode of one small JSON file (the roster is a handful
/// of agents, and the UI itself reloads it on every appear).
struct AgentEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [AgentEntity] {
        let wanted = Set(identifiers)
        return AgentStore.active().filter { wanted.contains($0.id) }.map(AgentEntity.init)
    }

    func entities(matching string: String) async throws -> [AgentEntity] {
        IntentNameMatch
            .filter(AgentStore.active(), query: string, name: \.name)
            .map(AgentEntity.init)
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        AgentStore.active().map(AgentEntity.init)
    }
}

// MARK: - Intents

/// "Neuen Chat starten", optionally with the first message already typed.
///
/// **The prompt is staged, not sent.** The app opens on a fresh conversation
/// with the text in the composer and the keyboard up; the user presses send.
/// That is a deliberate contract, for the same reason dictation does not
/// auto-send: an automation must not be able to spend provider tokens (or pull
/// a multi-GB local model into memory) while the phone is in a pocket. It also
/// keeps the model-autoselect rule intact — an unset model still shows the
/// setup banner instead of a request going out under a guessed model.
///
/// Cold, backgrounded or foreground, the behaviour is the same: the system
/// brings aiity to the front because of `openAppWhenRun`, `perform()` records
/// the request, and `RootView` performs the navigation — on appear if the
/// scene did not exist yet, immediately if it did.
struct StartChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Neuen Chat starten"
    static var description = IntentDescription(
        "Öffnet aiity mit einer neuen Unterhaltung. Ein mitgegebener Text steht im Eingabefeld — gesendet wird er erst, wenn du auf Senden tippst."
    )
    static var openAppWhenRun: Bool { true }

    /// Optional on purpose: no `requestValueDialog`, so Siri never interrogates
    /// someone who just wanted an empty chat.
    @Parameter(title: "Nachricht")
    var prompt: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Neuen aiity-Chat starten mit \(\.$prompt)")
    }

    init() {}

    init(prompt: String?) {
        self.prompt = prompt
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.request(.newChat(prompt: prompt ?? ""))
        return .result()
    }
}

/// "Mini-App öffnen" — straight into the sandboxed runner for a saved app.
///
/// Opening a mini-app is the one capability here that genuinely does something
/// on its own: the app is local HTML, so this needs no provider and costs
/// nothing. It still opens the app, because the runner *is* the UI.
struct OpenMiniAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Mini-App öffnen"
    static var description = IntentDescription(
        "Öffnet eine gespeicherte Mini-App in aiity."
    )
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Mini-App")
    var app: MiniAppEntity

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$app) in aiity öffnen")
    }

    init() {}

    init(app: MiniAppEntity) {
        self.app = app
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.request(.openMiniApp(id: app.id))
        return .result()
    }
}

/// "Agent fragen" — a fresh conversation whose only participant is the chosen
/// agent, with the question staged in the composer.
///
/// Same staging contract as `StartChatIntent`, and for a sharper reason: an
/// agent can be pinned to a different (often more expensive) provider than the
/// chat, so an auto-sending version of this would be the single easiest way for
/// a Shortcut to burn money unattended.
struct AskAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Agent fragen"
    static var description = IntentDescription(
        "Startet in aiity eine Unterhaltung mit einem deiner Agenten. Die Frage steht im Eingabefeld — gesendet wird sie erst, wenn du auf Senden tippst."
    )
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Agent")
    var agent: AgentEntity

    @Parameter(title: "Frage", requestValueDialog: "Was soll der Agent beantworten?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$agent) fragen: \(\.$question)")
    }

    init() {}

    init(agent: AgentEntity, question: String) {
        self.agent = agent
        self.question = question
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.request(.askAgent(id: agent.id, question: question))
        return .result()
    }
}

// MARK: - Siri phrases

/// What Siri listens for and what the Shortcuts app shows under "aiity".
///
/// Every phrase must contain `\(.applicationName)` — Apple rejects a provider
/// where one does not, and the failure mode is the whole provider silently not
/// registering rather than a build error. The app name is "aiity"
/// (`CFBundleDisplayName`), so the German phrasings read naturally around it.
///
/// Kept deliberately small. App Intents allows ten shortcuts; three that map to
/// real capabilities beat a dozen that mostly fail.
struct AiityAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartChatIntent(),
            phrases: [
                "Neuen Chat in \(.applicationName) starten",
                "Starte einen neuen Chat in \(.applicationName)",
                "Neue Unterhaltung in \(.applicationName)",
                "Start a new chat in \(.applicationName)",
                "New \(.applicationName) chat",
            ],
            shortTitle: "Neuer Chat",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: OpenMiniAppIntent(),
            phrases: [
                // Parameterised: Siri builds its vocabulary from
                // `MiniAppEntityQuery.suggestedEntities()`, which is why the
                // index has to be written before the user ever asks.
                "Öffne \(\.$app) in \(.applicationName)",
                "Mini-App in \(.applicationName) öffnen",
                "Open \(\.$app) in \(.applicationName)",
                "Open a mini app in \(.applicationName)",
            ],
            shortTitle: "Mini-App öffnen",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: AskAgentIntent(),
            phrases: [
                "Frage \(\.$agent) in \(.applicationName)",
                "Agent in \(.applicationName) fragen",
                "Ask \(\.$agent) in \(.applicationName)",
                "Ask an agent in \(.applicationName)",
            ],
            shortTitle: "Agent fragen",
            systemImageName: "person.2"
        )
    }
}
