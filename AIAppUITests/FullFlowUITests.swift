import XCTest

/// Hermetic end-to-end flow against tools/stub_llm_server.py (port 8555).
/// Chat is the default tab in v6; onboarding is skipped via a launch argument.
final class FullFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    // A CLOUD, image-capable preset (openai) pointed at the local stub. Cloud
    // providers get the agent tools (web_search / generate_image); a plain key
    // (not an oauth: token) keeps it on the OpenAI-compatible path, not Codex.
    private static let stubSettings = """
    {"presetId":"openai","baseURL":"http://127.0.0.1:8555/v1","model":"stub","searchEndpoint":"http://127.0.0.1:8555"}
    """

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PROVIDER_SETTINGS_JSON"] = Self.stubSettings
        app.launchEnvironment["AIITY_TEST_API_KEY"] = "stub-key"  // satisfy the needs-key gate
        // The stub preset is a cloud one with an explicit model, so the
        // empty-state idea fetch would otherwise be eligible and fire a stray
        // completion into a timing-sensitive flow.
        app.launchEnvironment["AIITY_DISABLE_SUGGESTIONS"] = "1"
        // Skip the first-run onboarding wizard (writes the completed flag).
        app.launchArguments += ["-onboarding.completed.v1", "1"]
    }

    func testFullMiniAppFlow() {
        app.launch()
        startFreshThread()

        // 1. Ask for an app — the stub first requests a web_search round.
        sendChatMessage("Recherchier kurz und bau mir eine Notiz-App")
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Laut Recherche'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 25), "assistant answer with research result should appear")

        // 2. Keep the generated mini-app.
        let keepButton = app.buttons["keep-app"]
        XCTAssertTrue(keepButton.waitForExistence(timeout: 10), "mini-app card should appear")
        keepButton.tap()

        // 3. Open the kept app from the Apps tab.
        openAppsTab()
        let libraryItem = app.buttons["library-app"].firstMatch
        XCTAssertTrue(libraryItem.waitForExistence(timeout: 10), "kept app should show up in the library")
        libraryItem.tap()
        let runner = app.webViews.firstMatch
        XCTAssertTrue(runner.waitForExistence(timeout: 15), "mini-app web view should load")
        app.buttons["miniapp-done"].tap()

        // 4. Continue the mini-app via the context menu → opens the Chat tab.
        libraryItem.press(forDuration: 1.2)
        let editAction = app.buttons["Mit KI bearbeiten"]
        XCTAssertTrue(editAction.waitForExistence(timeout: 10), "context menu should offer editing")
        editAction.tap()

        sendChatMessage("Mach den Hintergrund blau")
        let editedAnswer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'blauem Hintergrund'")).firstMatch
        XCTAssertTrue(editedAnswer.waitForExistence(timeout: 25), "edited mini-app answer should appear")
        let keepEdited = app.buttons["keep-app"]
        XCTAssertTrue(keepEdited.waitForExistence(timeout: 10))
        keepEdited.tap()

        // 5. Chat history must survive a restart. After relaunch the Chat tab
        //    shows the LIST, so the conversation has to be opened from a row.
        app.terminate()
        app.launch()
        dismissCrashNoticeIfShown()
        let rows = app.buttons.matching(identifier: "thread-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "the chat list should show past conversations")
        rows.firstMatch.tap()
        let restoredMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Hintergrund blau'")).firstMatch
        XCTAssertTrue(restoredMessage.waitForExistence(timeout: 15), "chat history should be restored after relaunch")

        // 6. A second chat is its own row; the first stays reachable.
        backToChatList()
        startFreshThread()
        XCTAssertTrue(
            app.staticTexts["Was soll ich bauen?"].waitForExistence(timeout: 10),
            "a new chat should show the empty state"
        )
        backToChatList()
        let oldThread = app.buttons.matching(
            NSPredicate(format: "identifier == 'thread-row' AND label CONTAINS 'Notizen'")
        ).firstMatch
        XCTAssertTrue(oldThread.waitForExistence(timeout: 10), "the editing thread should be listed by its title")
        oldThread.tap()
        XCTAssertTrue(restoredMessage.waitForExistence(timeout: 10), "reopening should restore that conversation")
    }

    /// Image generation: the stub scripts a generate_image tool call for a
    /// "Bild" request; the tool posts to /v1/images/generations, stores the
    /// PNG, and the chat shows it inline.
    func testImageGenerationShowsInlineImage() {
        app.launch()
        startFreshThread()
        sendChatMessage("Mach mir ein Bild von einer roten Katze")
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Hier ist dein Bild'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 25), "assistant should confirm the generated image")
        let image = app.images["generated-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 10), "the generated image should render inline in the chat")
    }

    /// End-to-end proof that a browser mini-app actually loads an external site.
    /// Network-dependent (loads example.com) — run to verify, not part of hermetic CI.
    func testBrowserMiniAppLoadsExampleCom() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1",
                          "Network-dependent; run with RUN_NETWORK_TESTS=1")
        app.launch()
        startFreshThread()
        sendChatMessage("Öffne example.com")
        let keep = app.buttons["keep-app"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        keep.tap()
        openAppsTab()
        let item = app.buttons["library-app"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()
        // Consent, then the real page must load in the web view.
        if app.alerts.buttons["Erlauben"].waitForExistence(timeout: 10) {
            app.alerts.buttons["Erlauben"].tap()
        }
        let loaded = app.webViews.staticTexts["Example Domain"]
        XCTAssertTrue(loaded.waitForExistence(timeout: 20), "the external site should load inside the browser mini-app")
    }

    /// "Öffne <url>" builds a browser mini-app deterministically — no model round.
    func testOpenUrlBuildsBrowserAppWithoutModel() {
        app.launch()
        startFreshThread()
        sendChatMessage("Öffne example.com")
        let keep = app.buttons["keep-app"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10), "a browser mini-app should be built for an open-url request")
        let host = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'example.com'")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5), "reply should name the host")
    }

    /// A network-capability mini-app must ask the user before it gets internet.
    func testNetworkMiniAppAsksConsent() {
        app.launch()
        startFreshThread()
        sendChatMessage("Bau eine Netz-App")
        let keep = app.buttons["keep-app"]
        XCTAssertTrue(keep.waitForExistence(timeout: 25), "network mini-app card should appear")
        keep.tap()

        openAppsTab()
        let item = app.buttons["library-app"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "kept app should be in the library")
        item.tap()

        // Consent prompt gates the relaxed (network) capability.
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10), "a network mini-app must prompt for consent")
        let allow = app.alerts.buttons["Erlauben"]
        XCTAssertTrue(allow.exists, "consent alert should offer Erlauben / Nur offline")
        allow.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "app runs after consent")
    }

    /// With the "Web-Tools für lokale Modelle" toggle on, a local-style provider
    /// runs a web_search round (default is no tools for local).
    func testLocalToolsToggleEnablesWebSearch() {
        app.launchEnvironment["PROVIDER_SETTINGS_JSON"] = """
        {"presetId":"ollama","baseURL":"http://127.0.0.1:8555/v1","model":"stub","searchEndpoint":"http://127.0.0.1:8555"}
        """
        app.launchArguments += ["-prefs.allowLocalTools.v1", "1"]
        app.launch()
        startFreshThread()
        sendChatMessage("Recherchier kurz etwas Aktuelles")
        let answer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Laut Recherche'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 25), "local model with tools enabled should run a web_search round")
    }

    /// Threads persist in the simulator across test runs; stale tool results
    /// in a restored thread would derail the stub's content-based script. Each
    /// test therefore begins in a brand-new conversation.
    /// The Chat tab now opens the conversation LIST (WhatsApp-style), so every
    /// flow has to create and enter a chat before it can type anything.
    private func startFreshThread() {
        let compose = app.buttons["new-chat"]
        XCTAssertTrue(compose.waitForExistence(timeout: 15), "compose button should exist on the chat list")
        compose.tap()
        let solo = app.buttons["new-solo-chat"]
        XCTAssertTrue(solo.waitForExistence(timeout: 10), "new-chat sheet should offer a solo chat")
        solo.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["chat-input"].firstMatch.waitForExistence(timeout: 15),
            "creating a chat should push into it"
        )
    }

    /// Back out of an open conversation to the list.
    private func backToChatList() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
    }

    /// The test's own `terminate()` reads as an unexpected end on the next
    /// launch (a SIGKILL leaves no clean-exit marker), so DiagnosticsRecorder's
    /// crash notice slides into the chat list a beat after it renders — via
    /// `.task` — shifting the thread rows between XCUITest's hit-point
    /// snapshot and the synthesized tap, which then lands on the banner
    /// instead of the row. The banner is real, intended app behavior; the
    /// test just clears it deterministically before touching rows.
    private func dismissCrashNoticeIfShown() {
        let notice = app.descendants(matching: .any)["crash-notice"].firstMatch
        guard notice.waitForExistence(timeout: 5) else { return }
        app.buttons["Hinweis schließen"].firstMatch.tap()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, notice.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    /// Switch to the Apps tab, dropping the keyboard first when the simulator
    /// shows a software one. With the keyboard up the tab bar is covered, and
    /// XCUITest computes a {-1,-1} hit point for the covered tab button — the
    /// tap silently lands nowhere and the test then fails one assertion later
    /// ("kept app should show up in the library") on machines whose simulator
    /// has no hardware keyboard attached. Do what a user does: drag the
    /// transcript (ChatView maps that to scrollDismissesKeyboard(.immediately)),
    /// then navigate.
    private func openAppsTab() {
        if !app.keyboards.allElementsBoundByIndex.isEmpty {
            let window = app.windows.firstMatch
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            start.press(forDuration: 0.15, thenDragTo: end)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !app.keyboards.allElementsBoundByIndex.isEmpty {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }
        app.tabBars.buttons["Apps"].tap()
    }

    private func sendChatMessage(_ text: String) {
        let input = app.descendants(matching: .any)["chat-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15), "chat input should exist")
        input.tap()
        input.typeText(text)
        app.buttons["chat-send"].tap()
    }
}
