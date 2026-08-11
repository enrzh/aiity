import XCTest

final class ChatWorkflowUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let stubSettings = """
    {"presetId":"openai","baseURL":"http://127.0.0.1:8555/v1","model":"stub","searchEndpoint":"http://127.0.0.1:8555"}
    """

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PROVIDER_SETTINGS_JSON"] = Self.stubSettings
        app.launchEnvironment["AIITY_TEST_API_KEY"] = "stub-key"
        app.launchEnvironment["AIITY_DISABLE_SUGGESTIONS"] = "1"
        app.launchArguments += ["-onboarding.completed.v1", "1"]
    }

    func testComposerExposesAttachmentPickerAndSendRoute() {
        app.launch()
        openFreshChat()

        let attachments = app.buttons["chat-attachments"]
        XCTAssertTrue(attachments.waitForExistence(timeout: 15))
        attachments.tap()
        XCTAssertTrue(app.buttons["Foto"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Datei"].exists)
        XCTAssertTrue(app.buttons["Senden"].exists)
    }

    func testAttachmentRemovalAndSendRoute() {
        app.launchEnvironment["AIITY_UI_TEST_ATTACHMENTS"] = "1"
        app.launch()
        openFreshChat()

        let remove = app.buttons["chat-attachment-remove-ui-test-attachment"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        XCTAssertFalse(remove.waitForExistence(timeout: 2))

        typeText("fixture message", into: "chat-input")
        let send = app.buttons["chat-send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.staticTexts["fixture message"].waitForExistence(timeout: 10))
    }

    func testJumpToLatestAfterUserScrollsAway() {
        app.launchEnvironment["AIITY_UI_TEST_SCROLL_FIXTURE"] = "1"
        app.launch()
        openFreshChat()

        XCTAssertTrue(app.staticTexts["fixture-latest"].waitForExistence(timeout: 10))

        let scroll = app.scrollViews["chat-transcript"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        scroll.swipeDown()
        let jump = app.buttons["jump-to-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.tap()
        XCTAssertTrue(waitFor(timeout: 5) { !jump.exists })
    }

    func testScrollStaysPutWhenNewContentArrivesAwayFromLatest() {
        app.launchEnvironment["AIITY_UI_TEST_SCROLL_FIXTURE"] = "1"
        app.launch()
        openFreshChat()

        XCTAssertTrue(app.staticTexts["fixture-latest"].waitForExistence(timeout: 10))
        let scroll = app.scrollViews["chat-transcript"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        scroll.swipeDown()

        let anchor = app.staticTexts["fixture-anchor"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        let before = anchor.frame.minY
        let deliver = app.buttons["ui-test-deliver-content"]
        XCTAssertTrue(deliver.waitForExistence(timeout: 5))
        deliver.tap()

        XCTAssertTrue(waitFor(timeout: 5) { app.buttons["jump-to-latest"].exists })
        XCTAssertTrue(waitFor(timeout: 5) { abs(anchor.frame.minY - before) < 20 })
    }

    func testAttachedImageOpensAndDismissesSharedPreview() {
        app.launchEnvironment["AIITY_UI_TEST_IMAGE_ATTACHMENT"] = "1"
        app.launch()
        openFreshChat()

        let image = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'chat-attachment-preview-'")
        ).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.tap()
        let close = app.buttons["media-preview-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertFalse(close.exists)
    }

    func testDelayedToolShowsRunningThenCompletionState() {
        app.launchEnvironment["AIITY_UI_TEST_DELAYED_TOOL"] = "1"
        app.launch()
        openFreshChat()
        typeText("fixture delayed tool", into: "chat-input")
        app.buttons["chat-send"].tap()

        let tool = app.descendants(matching: .any)["chat-tool-generate_image"].firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(timeout: 3) { tool.value as? String == "Läuft" })
        XCTAssertTrue(waitFor(timeout: 10) { tool.value as? String == "Abgeschlossen" })
    }

    private func openFreshChat() {
        let newChat = app.buttons["new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        newChat.tap()
        let solo = app.buttons["new-solo-chat"]
        XCTAssertTrue(solo.waitForExistence(timeout: 5))
        solo.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-input"].waitForExistence(timeout: 10))
    }

    private func typeText(_ text: String, into identifier: String) {
        let field = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
    }
}
