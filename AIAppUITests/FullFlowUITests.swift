import XCTest

/// Hermetic end-to-end flow against tools/stub_llm_server.py (port 8555):
/// ask a question (agent does a web_search round), receive a mini-app, keep
/// it, open it from the library, edit it via chat, and verify the chat
/// history survives an app restart.
final class FullFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    private static let stubSettings = """
    {"kind":"openAICompatible","baseURL":"http://127.0.0.1:8555/v1","model":"stub","searchEndpoint":"http://127.0.0.1:8555"}
    """

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PROVIDER_SETTINGS_JSON"] = Self.stubSettings
    }

    func testFullMiniAppFlow() {
        app.launch()

        // 1. Ask for an app — the stub first requests a web_search round.
        sendChatMessage("Recherchier kurz und bau mir eine Notiz-App")
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Laut Recherche'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 25), "assistant answer with research result should appear")

        // 2. Keep the generated mini-app.
        let keepButton = app.buttons["keep-app"]
        XCTAssertTrue(keepButton.waitForExistence(timeout: 10), "mini-app card should appear")
        keepButton.tap()

        // 3. Open it from the library (swipe first: the keyboard covers the tab bar).
        app.swipeDown()
        app.tabBars.buttons["Apps"].tap()
        let libraryItem = app.buttons["library-app"].firstMatch
        XCTAssertTrue(libraryItem.waitForExistence(timeout: 10), "kept app should show up in the library")
        libraryItem.tap()
        let runner = app.webViews.firstMatch
        XCTAssertTrue(runner.waitForExistence(timeout: 15), "mini-app web view should load")
        app.buttons["Fertig"].tap()

        // 4. Continue the mini-app in the chat (context menu -> edit).
        libraryItem.press(forDuration: 1.2)
        let editAction = app.buttons["Im Chat bearbeiten"]
        XCTAssertTrue(editAction.waitForExistence(timeout: 10), "context menu should offer editing")
        editAction.tap()

        sendChatMessage("Mach den Hintergrund blau")
        let editedAnswer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'blauem Hintergrund'")).firstMatch
        XCTAssertTrue(editedAnswer.waitForExistence(timeout: 25), "edited mini-app answer should appear")
        let keepEdited = app.buttons["keep-app"]
        XCTAssertTrue(keepEdited.waitForExistence(timeout: 10))
        keepEdited.tap()

        // 5. Chat history must survive a restart.
        app.terminate()
        app.launch()
        let restoredMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Hintergrund blau'")).firstMatch
        XCTAssertTrue(restoredMessage.waitForExistence(timeout: 15), "chat history should be restored after relaunch")

        // 6. Threads: a new chat starts empty, the old one stays reachable.
        app.buttons["chat-new"].tap()
        let emptyState = app.staticTexts["Was soll ich bauen?"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10), "new thread should show the empty state")
        app.buttons["chat-threads"].tap()
        let threadRows = app.buttons.matching(identifier: "thread-row")
        XCTAssertTrue(threadRows.firstMatch.waitForExistence(timeout: 10), "threads list should show rows")
        XCTAssertGreaterThanOrEqual(threadRows.count, 2, "old and new thread should both be listed")
        let oldThread = app.buttons.matching(NSPredicate(format: "identifier == 'thread-row' AND label CONTAINS 'Notizen'")).firstMatch
        XCTAssertTrue(oldThread.waitForExistence(timeout: 10), "the editing thread should be listed by its title")
        oldThread.tap()
        XCTAssertTrue(restoredMessage.waitForExistence(timeout: 10), "switching back should restore the old conversation")
    }

    private func sendChatMessage(_ text: String) {
        let input = app.descendants(matching: .any)["chat-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15), "chat input should exist")
        input.tap()
        input.typeText(text)
        app.buttons["chat-send"].tap()
    }
}
