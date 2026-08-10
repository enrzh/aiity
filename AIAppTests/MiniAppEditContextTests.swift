import XCTest
@testable import AIApp

final class MiniAppEditContextTests: XCTestCase {

    /// Stopping mid-tool-loop must not leave an assistant `tool_use` without its
    /// `tool_result`: Anthropic rejects that thread forever ("tool_use ids found
    /// without tool_result"), which permanently bricks the conversation.
    @MainActor
    func testDropDanglingToolCallsAfterStop() {
        let session = ChatSession()
        let answered = ToolCallData(id: "call_ok", name: "web_search", argumentsJSON: "{}")
        let dangling = ToolCallData(id: "call_orphan", name: "fetch_url", argumentsJSON: "{}")

        session.messages = [
            ChatMessage(role: .user, text: "hi"),
            ChatMessage(role: .assistant, text: "looking", toolCalls: [answered]),
            ChatMessage(role: .tool, text: "result", toolCallId: "call_ok", toolName: "web_search"),
            ChatMessage(role: .assistant, text: "", toolCalls: [dangling]),
        ]
        session.dropDanglingToolCalls()

        let remaining = session.messages.flatMap(\.toolCalls).map(\.id)
        XCTAssertEqual(remaining, ["call_ok"], "unanswered tool_use must be dropped")
        XCTAssertFalse(
            session.messages.contains { $0.role == .assistant && $0.text.isEmpty && $0.toolCalls.isEmpty },
            "an assistant turn left with nothing should be removed entirely"
        )
    }

    func testSourcePinMessageContainsFullHTML() {
        let html = "<!DOCTYPE html><html><body><h1>MiniCraft</h1></body></html>"
        let ctx = ChatSession.EditingContext(id: UUID(), name: "MiniCraft 3D", html: html)
        let pin = ChatSession.sourcePinMessage(for: ctx)
        XCTAssertEqual(pin.role, .user)
        XCTAssertTrue(ChatSession.isSourcePinMessage(pin))
        XCTAssertTrue(pin.text.contains(ChatSession.miniAppSourceMarker))
        XCTAssertTrue(pin.text.contains("MiniCraft 3D"))
        XCTAssertTrue(pin.text.contains(html))
        XCTAssertTrue(pin.text.contains("```html"))
    }

    func testSystemPromptEditingPointerDoesNotInlineHugeHTML() {
        let huge = String(repeating: "x", count: 20_000)
        let ctx = ChatSession.EditingContext(id: UUID(), name: "Big", html: huge)
        var settings = ProviderSettings()
        settings.presetId = "anthropic"
        settings.model = "claude-opus-4"
        let system = ChatSession.buildSystemPrompt(settings: settings, editing: ctx, userText: "fix it")
        XCTAssertTrue(system.contains("EDITING MINI-APP") || system.contains("[[MINIAPP_SOURCE]]"))
        XCTAssertTrue(system.contains(ChatSession.miniAppSourceMarker))
        // Full body must NOT be dumped into system (OAuth trim would drop it).
        XCTAssertFalse(system.contains(huge))
    }

    /// Starting an edit must PUSH the new conversation, not just select the
    /// Chat tab. `ChatListView` navigates on `openThreadId`, so leaving it nil
    /// dropped the user on the conversation list — the mini-app runner's AI
    /// button then looked like it did nothing.
    @MainActor
    func testStartEditingOpensTheNewConversation() {
        let session = ChatSession()
        session.startEditing(id: UUID(), name: "Notizen", html: "<html></html>")

        XCTAssertTrue(session.chatPresented, "the Chat tab must be selected")
        XCTAssertEqual(session.openThreadId, session.activeThreadIdForTesting,
                       "the edit thread must be the one pushed on the Chat tab")
        XCTAssertNotNil(session.editingContext)
    }

    @MainActor
    func testStartEditingDraftOpensTheNewConversation() {
        let session = ChatSession()
        session.startEditingDraft(name: "Vorschau", html: "<html></html>")

        XCTAssertTrue(session.chatPresented)
        XCTAssertEqual(session.openThreadId, session.activeThreadIdForTesting)
    }

    /// The refusal path must not navigate either: pushing a thread that was
    /// never created would show the running conversation under a new identity.
    @MainActor
    func testStartEditingWhileBusyDoesNotNavigate() {
        let session = ChatSession()
        guard session.newThread() != nil else { return XCTFail("no thread") }
        session.busy = true
        session.openThreadId = nil
        session.chatPresented = false

        session.startEditing(id: UUID(), name: "Timer", html: "<html></html>")

        XCTAssertNil(session.openThreadId, "a refused edit must not push anything")
        XCTAssertFalse(session.chatPresented)
        XCTAssertNotNil(session.errorMessage)
    }

    @MainActor
    func testEnsureSourcePinnedInsertsAndRefreshes() {
        let session = ChatSession()
        let html1 = "<html><body>v1</body></html>"
        session.startEditing(id: UUID(), name: "Game", html: html1)
        XCTAssertEqual(session.messages.filter { ChatSession.isSourcePinMessage($0) }.count, 1)
        XCTAssertTrue(session.messages.contains { $0.text.contains("v1") })

        session.updateEditingSource(html: "<html><body>v2</body></html>", name: "Game")
        let pins = session.messages.filter { ChatSession.isSourcePinMessage($0) }
        XCTAssertEqual(pins.count, 1)
        XCTAssertTrue(pins[0].text.contains("v2"))
        XCTAssertFalse(pins[0].text.contains("v1"))
    }
}
