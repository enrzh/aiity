import XCTest
@testable import AIApp

/// Covers the parts of delegation that are decidable without a network call:
/// how an agent resolves its brain, and how `ask_agent` routes (or refuses).
final class AgentDelegationTests: XCTestCase {

    private func agent(
        _ name: String,
        role: String = "Recherchiert Fakten",
        presetId: String = "",
        model: String = ""
    ) -> AgentDefinition {
        AgentDefinition(name: name, role: role, presetId: presetId, model: model)
    }

    // MARK: - Slugs

    func testSlugIsStableForToolArguments() {
        XCTAssertEqual(agent("Rechercheur").slug, "rechercheur")
        XCTAssertEqual(agent("Code Review").slug, "code-review")
        XCTAssertEqual(agent("Übersetzer (DE→EN)").slug, "übersetzer-de-en")
        // Runs of punctuation collapse rather than leaving empty segments.
        XCTAssertEqual(agent("A  --  B").slug, "a-b")
    }

    // MARK: - Which brain an agent runs on

    func testAgentWithoutProviderInheritsTheChatProvider() {
        var chat = ProviderSettings()
        chat.presetId = "anthropic"
        chat.model = "claude-sonnet-4-5"

        let resolved = agent("Helfer").settings(fallback: chat)
        XCTAssertEqual(resolved.presetId, "anthropic")
        XCTAssertEqual(resolved.effectiveModel, "claude-sonnet-4-5")
    }

    func testAgentModelOverridesInheritedProviderModel() {
        var chat = ProviderSettings()
        chat.presetId = "openrouter"
        chat.model = "openai/gpt-4o-mini"

        let resolved = agent("Prüfer", model: "anthropic/claude-sonnet-4").settings(fallback: chat)
        XCTAssertEqual(resolved.presetId, "openrouter", "keeps the inherited provider")
        XCTAssertEqual(resolved.effectiveModel, "anthropic/claude-sonnet-4")
    }

    func testAgentWithOwnProviderIgnoresTheChatProvider() {
        var chat = ProviderSettings()
        chat.presetId = "anthropic"
        chat.model = "claude-sonnet-4-5"

        let resolved = agent("Lokal", presetId: "ollama", model: "qwen2.5").settings(fallback: chat)
        XCTAssertEqual(resolved.presetId, "ollama")
        XCTAssertEqual(resolved.effectiveModel, "qwen2.5")
    }

    // MARK: - ask_agent routing

    private func tool(_ agents: [AgentDefinition]) -> AskAgentTool {
        var chat = ProviderSettings()
        chat.presetId = "openrouter"
        return AskAgentTool(agents: agents, chatSettings: chat)
    }

    func testSpecEnumeratesOnlyTheGivenAgents() {
        let spec = tool([agent("Rechercheur"), agent("Code Review")]).spec
        let properties = spec.parameters["properties"] as? [String: Any]
        let agentParam = properties?["agent"] as? [String: Any]
        XCTAssertEqual(agentParam?["enum"] as? [String], ["rechercheur", "code-review"])
        XCTAssertEqual(spec.name, "ask_agent")
    }

    func testEmptyTaskIsRefusedWithoutRunningAnything() async {
        let result = await tool([agent("Rechercheur")])
            .run(argumentsJSON: #"{"agent":"rechercheur","task":"   "}"#)
        XCTAssertTrue(result.text.hasPrefix("Error:"), result.text)
    }

    func testUnknownAgentNamesTheOnesThatExist() async {
        let result = await tool([agent("Rechercheur")])
            .run(argumentsJSON: #"{"agent":"nobody","task":"do a thing"}"#)
        XCTAssertTrue(result.text.hasPrefix("Error:"), result.text)
        XCTAssertTrue(result.text.contains("rechercheur"),
                      "the error should list the available agents, got: \(result.text)")
    }

    /// A model that echoes the display name instead of the slug must still route.
    func testDisplayNameAlsoResolves() async {
        // "Nirgendwo" has no provider account in the test environment, so the run
        // stops at the credential check — which is itself proof it resolved the
        // agent rather than failing to find it.
        let result = await tool([agent("Rechercheur", presetId: "anthropic")])
            .run(argumentsJSON: #"{"agent":"Rechercheur","task":"do a thing"}"#)
        XCTAssertFalse(result.text.contains("kein Agent"),
                       "display name should resolve, got: \(result.text)")
    }

    // MARK: - Delegation depth

    /// The invariant that stops agents recursing into each other.
    func testWorkersNeverReceiveTheDelegationTool() async {
        var settings = ProviderSettings()
        settings.presetId = "openrouter"

        let workerTools = await ToolRegistry.makeTools(settings: settings, apiKey: "sk-test")
        XCTAssertFalse(
            workerTools.contains { $0.spec.name == AskAgentTool.toolName },
            "a worker must not be able to delegate — that is what bounds the depth"
        )
    }
}

/// The bug that made a "group chat" three monologues: a model treats every
/// `.assistant` message as its OWN prior turn, so peers handed over in the
/// assistant role read as its own train of thought — and nobody argues with
/// themselves.
final class GroupPerspectiveTests: XCTestCase {
    private let planner = AgentDefinition(name: "Planer", role: "plant")
    private let critic = AgentDefinition(name: "Kritiker", role: "kritisiert")

    private var transcript: [ChatMessage] {
        [
            ChatMessage(role: .user, text: "Wie gehen wir das an?"),
            ChatMessage(role: .assistant, text: "Erst A, dann B.", authorName: "Planer"),
            ChatMessage(role: .assistant, text: "B ist riskant.", authorName: "Kritiker"),
        ]
    }

    func testAnAgentSeesOnlyItsOwnTurnsAsAssistant() {
        let view = GroupChatRunner.perspective(of: planner, transcript: transcript)
        let assistantTexts = view.filter { $0.role == .assistant }.map(\.text)
        XCTAssertEqual(assistantTexts, ["Erst A, dann B."],
                       "only the Planer's own contribution may be an assistant turn")
    }

    func testPeersArriveAsNamedUserMessages() {
        let view = GroupChatRunner.perspective(of: planner, transcript: transcript)
        let userTexts = view.filter { $0.role == .user }.map(\.text)
        XCTAssertTrue(userTexts.contains("Wie gehen wir das an?"))
        XCTAssertTrue(userTexts.contains("Kritiker: B ist riskant."),
                      "a peer must arrive as somebody else's message, named")
    }

    /// The same transcript looks different to each participant — that is what
    /// makes it a conversation rather than a shared monologue.
    func testEachAgentGetsItsOwnPerspective() {
        let plannerView = GroupChatRunner.perspective(of: planner, transcript: transcript)
        let criticView = GroupChatRunner.perspective(of: critic, transcript: transcript)
        XCTAssertNotEqual(
            plannerView.map { "\($0.role):\($0.text)" },
            criticView.map { "\($0.role):\($0.text)" }
        )
        XCTAssertEqual(criticView.filter { $0.role == .assistant }.map(\.text), ["B ist riskant."])
    }

    /// Tool plumbing is not conversation and must not reach a peer.
    func testToolAndSystemMessagesAreDropped() {
        let noisy = transcript + [
            ChatMessage(role: .tool, text: "{\"results\":[]}", toolName: "web_search"),
            ChatMessage(role: .system, text: "interner Prompt"),
        ]
        let view = GroupChatRunner.perspective(of: planner, transcript: noisy)
        XCTAssertFalse(view.contains { $0.role == .tool || $0.role == .system })
        XCTAssertFalse(view.contains { $0.text.contains("interner Prompt") })
    }

    /// Suggested agents must not preset a provider — the model is the user's
    /// cost decision.
    func testSuggestionsLeaveTheModelToTheUser() {
        XCTAssertFalse(AgentSuggestion.all.isEmpty)
        for template in AgentSuggestion.all {
            let agent = AgentSuggestion.agent(from: template)
            XCTAssertTrue(agent.presetId.isEmpty, "\(template.name) must not preset a provider")
            XCTAssertTrue(agent.model.isEmpty, "\(template.name) must not preset a model")
            XCTAssertFalse(agent.role.isEmpty)
            XCTAssertFalse(template.modelHint.isEmpty, "each suggestion should say what model suits it")
        }
    }
}

/// The chat mode decides how much the agent does before asking.
final class ChatModeTests: XCTestCase {
    /// Plan mode is enforced by withholding tools, not by asking nicely —
    /// a prompt is a request, an empty tool list is a guarantee.
    func testOnlyPlanModeWithholdsTools() {
        XCTAssertFalse(ChatMode.plan.allowsTools)
        XCTAssertTrue(ChatMode.approval.allowsTools)
        XCTAssertTrue(ChatMode.auto.allowsTools)
    }

    /// Auto is the current behaviour and must add nothing to the prompt.
    func testAutoAddsNoInstructions() {
        XCTAssertTrue(ChatMode.auto.instructions.isEmpty)
        XCTAssertFalse(ChatMode.approval.instructions.isEmpty)
        XCTAssertFalse(ChatMode.plan.instructions.isEmpty)
    }

    /// Approval must not turn into "ask before answering anything" — that
    /// would make ordinary conversation unusable.
    func testApprovalExemptsPlainAnswers() {
        XCTAssertTrue(ChatMode.approval.instructions.contains("beantworten"))
    }

    func testEveryModeIsSelectableAndLabelled() {
        XCTAssertEqual(ChatMode.allCases.count, 3)
        for mode in ChatMode.allCases {
            XCTAssertFalse(mode.title.isEmpty, mode.rawValue)
            XCTAssertFalse(mode.detail.isEmpty, mode.rawValue)
            XCTAssertFalse(mode.systemImage.isEmpty, mode.rawValue)
            XCTAssertEqual(ChatMode(rawValue: mode.rawValue), mode, "must round-trip for persistence")
        }
    }
}
