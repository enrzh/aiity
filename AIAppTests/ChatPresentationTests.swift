import Foundation
import XCTest
@testable import AIApp

final class ChatPresentationTests: XCTestCase {
    func testNearBottomUsesAStableThreshold() {
        XCTAssertTrue(ChatView.isNearBottom(contentBottom: 798, viewportBottom: 800))
        XCTAssertFalse(ChatView.isNearBottom(contentBottom: 880, viewportBottom: 800))
    }

    func testMarkdownUsesFullBlockParsingAndPlainTextFallback() throws {
        let parsed = ChatView.markdownAttributedString("# Überschrift\n\n- Punkt")
        XCTAssertEqual(String(parsed.characters), "ÜberschriftPunkt")

        let plain = ChatView.markdownAttributedString("kein Markdown")
        XCTAssertEqual(String(plain.characters), "kein Markdown")
    }

    func testToolVisualStateDerivesActiveCompletedAndFailed() {
        let call = ToolCallData(id: "call-1", name: "web_search", argumentsJSON: "{}")
        let pending = ChatMessage(role: .assistant, text: "", toolCalls: [call])
        XCTAssertEqual(
            ChatView.toolVisualState(for: call, messages: [pending], isBusy: true),
            .active
        )

        let completed = ChatMessage(
            role: .tool,
            text: "Quelle gefunden",
            toolCallId: call.id,
            toolName: call.name
        )
        XCTAssertEqual(
            ChatView.toolVisualState(for: call, messages: [pending, completed], isBusy: false),
            .completed
        )

        let failed = ChatMessage(
            role: .tool,
            text: "Error: Verbindung fehlgeschlagen",
            toolCallId: call.id,
            toolName: call.name
        )
        XCTAssertEqual(
            ChatView.toolVisualState(for: call, messages: [pending, failed], isBusy: false),
            .failed
        )
    }

    func testMissingMediaUsesLocalizedPlaceholderForImages() {
        XCTAssertEqual(
            ChatView.mediaPlaceholder(for: .image),
            String(localized: "Bild nicht verfügbar")
        )
    }
}
