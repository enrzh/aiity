import XCTest
@testable import AIApp

final class MiniAppEditContextTests: XCTestCase {
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
