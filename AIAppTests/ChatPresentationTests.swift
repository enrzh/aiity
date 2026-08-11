import Foundation
import XCTest
@testable import AIApp

final class ChatPresentationTests: XCTestCase {
    func testNearBottomUsesAStableThreshold() {
        XCTAssertTrue(ChatView.isNearBottom(contentBottom: 872, viewportBottom: 800))
        XCTAssertFalse(ChatView.isNearBottom(contentBottom: 873, viewportBottom: 800))
        XCTAssertFalse(ChatView.isNearBottom(contentBottom: 880, viewportBottom: 800))
    }

    func testTrueContentBottomIncludesComposerClearance() {
        XCTAssertEqual(
            ChatView.trueContentBottom(contentTop: -512, contentHeight: 1312, sentinelBottom: 700),
            800
        )
        XCTAssertEqual(
            ChatView.trueContentBottom(contentTop: 0, contentHeight: 0, sentinelBottom: 700),
            700
        )
    }

    func testHTMLFenceStrippingHonorsBoundariesAndUnclosedFallback() {
        XCTAssertEqual(
            ChatView.strippingHTMLFence(from: "Vorher\n```html\n<h1>App</h1>\n```\nNachher"),
            "Vorher\n\nNachher"
        )
        XCTAssertEqual(
            ChatView.strippingHTMLFence(from: "```html\n<h1>App</h1>"),
            "```html\n<h1>App</h1>"
        )
        XCTAssertEqual(
            ChatView.strippingHTMLFence(from: "```html-not-a-fence\ntext"),
            "```html-not-a-fence\ntext"
        )
    }

    func testMarkdownUsesFullFormattingAndPlainTextFallback() {
        let parsed = ChatView.markdownAttributedString("**bold** and [link](https://example.com)")
        XCTAssertTrue(parsed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(parsed.runs.contains { $0.link == URL(string: "https://example.com") })

        let plain = ChatView.markdownAttributedString("kein Markdown")
        XCTAssertEqual(String(plain.characters), "kein Markdown")
    }

    func testMarkdownParserFallbackUsesPlainTextWhenInjectedParserThrows() {
        let fallback = ChatView.markdownAttributedString("**unparseable**", parser: { _ in
            throw MarkdownParserTestError.failed
        })

        XCTAssertEqual(String(fallback.characters), "**unparseable**")
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

        let imageFailures = [
            "Die Adresse des Bild-Anbieters ist ungültig: https://example.com",
            "Bildgenerierung: Antwort des Anbieters war kein JSON (oops)",
            "Das Bild-Modell 'chat' hat kein Bild erzeugt, sondern geantwortet: nein",
            "Der Anbieter hat kein Bild geliefert (leere Antwort).",
            "Bilddaten des Anbieters ließen sich nicht dekodieren (ungültiges Base64).",
            "Der Anbieter hat Daten geliefert, die kein Bild sind.",
            "Der Anbieter hat eine unbrauchbare Bild-URL geliefert.",
            "Das Bild konnte nicht gespeichert werden (kein Speicherplatz?).",
            "Das erzeugte Bild ließ sich nicht laden (HTTP 500 beim Abruf).",
            "Unter der Bild-URL des Anbieters lag kein Bild.",
        ]
        for failure in imageFailures {
            XCTAssertEqual(ChatView.toolResultState(failure), .failed, failure)
        }
        XCTAssertEqual(
            ChatView.toolResultState("Dieser Bericht beschreibt einen fehlgeschlagenen Versuch aus 2024."),
            .completed
        )
    }

    func testMissingMediaUsesLocalizedPlaceholderForImages() {
        XCTAssertEqual(
            ChatView.mediaPlaceholder(for: .image),
            String(localized: "Bild nicht verfügbar")
        )
    }

    func testComposerGatesSendAndExposesImportingState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chatView = try String(
            contentsOf: root.appendingPathComponent("AIApp/Views/ChatView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(chatView.contains("canSend: !attachmentImportState.isImporting"))
        XCTAssertTrue(chatView.contains("attachmentImportState.invalidate()"))
        XCTAssertTrue(chatView.contains("guard !attachmentImportState.isImporting else { return }"))
    }
}

private enum MarkdownParserTestError: Error {
    case failed
}
