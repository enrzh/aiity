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
        // The button relabels to "Gespeichert" once the app is in the library,
        // which is what proves the tap landed (it stays in the tree either way).
        // Counted, not matched: earlier cards keep their "Gespeichert" button in
        // the transcript, so only a NEW one means this tap landed.
        let keptBefore = keptCount
        XCTAssertTrue(tap(keepButton, untilTrue: { self.keptCount > keptBefore }),
                      "keeping should confirm")

        // 3. Open the kept app from the Apps tab.
        openAppsTab()
        let libraryItem = app.buttons["library-app"].firstMatch
        XCTAssertTrue(libraryItem.waitForExistence(timeout: 10), "kept app should show up in the library")
        let runner = app.webViews.firstMatch
        XCTAssertTrue(tap(libraryItem, until: runner), "mini-app web view should load")
        XCTAssertTrue(tap(app.buttons["miniapp-done"], untilGone: runner),
                      "closing the runner should dismiss the mini-app sheet")

        // 4. Continue the mini-app via the context menu → opens the Chat tab.
        libraryItem.press(forDuration: 1.2)
        let editAction = app.buttons["Mit KI bearbeiten"]
        XCTAssertTrue(editAction.waitForExistence(timeout: 10), "context menu should offer editing")
        XCTAssertTrue(tap(editAction, until: app.descendants(matching: .any)["chat-input"].firstMatch),
                      "editing should open the composer on the Chat tab")

        sendChatMessage("Mach den Hintergrund blau")
        let editedAnswer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'blauem Hintergrund'")).firstMatch
        XCTAssertTrue(editedAnswer.waitForExistence(timeout: 25), "edited mini-app answer should appear")
        let keepEdited = app.buttons["keep-app"]
        XCTAssertTrue(keepEdited.waitForExistence(timeout: 10))
        let keptBeforeEdit = keptCount
        XCTAssertTrue(tap(keepEdited, untilTrue: { self.keptCount > keptBeforeEdit }),
                      "keeping the edit should confirm")

        // 5. Chat history must survive a restart. After relaunch the Chat tab
        //    shows the LIST, so the conversation has to be opened from a row.
        app.terminate()
        app.launch()
        dismissCrashNoticeIfShown(in: app)
        let rows = app.buttons.matching(identifier: "thread-row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "the chat list should show past conversations")
        let restoredMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Hintergrund blau'")).firstMatch
        XCTAssertTrue(tap(rows.firstMatch, until: restoredMessage),
                      "chat history should be restored after relaunch")

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
        XCTAssertTrue(tap(oldThread, until: restoredMessage),
                      "reopening should restore that conversation")
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

    /// Deleting a mini-app: long-press the tile → Löschen → confirm. The library
    /// is a grid, so there is no list row to swipe. The confirmation is a
    /// CENTERED `.alert` (user request) rather than a bottom sheet. Deletion is
    /// irreversible and syncs over iCloud, so the one confirmation step stays.
    func testDeletingAMiniAppConfirmsInACenteredAlert() {
        app.launch()
        // Built straight from the "Website als App" sheet rather than through
        // chat: this leaves no conversation behind, so it cannot reorder the
        // thread list that the full-flow test reads after its relaunch.
        // openAppsTab() now verifies the tab actually came up (add-webapp is
        // its toolbar item), so the caller can go straight on.
        openAppsTab()
        let addWebApp = app.buttons["add-webapp"]
        let urlField = app.textFields["webapp-url"]
        XCTAssertTrue(tap(addWebApp, until: urlField), "the web-app sheet should ask for an address")
        typeText("youtube.com", into: "webapp-url", in: app)
        app.buttons["webapp-create"].tap()

        let tiles = app.buttons.matching(identifier: "library-app")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "the kept app should be in the library")
        let before = tiles.count

        tiles.firstMatch.press(forDuration: 1.2)
        let deleteAction = app.buttons["Löschen"].firstMatch
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 10), "the long-press menu should offer Löschen")
        deleteAction.tap()

        // Centered alert, not a bottom sheet: the destructive confirmation is
        // deliberately an `.alert` (user request), which XCUITest exposes in
        // app.alerts. A confirmationDialog would land in app.sheets instead.
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "deleting should ask in a centered alert, not a bottom sheet")
        XCTAssertEqual(app.sheets.count, 0, "the confirmation must not slide up as a sheet")
        // SwiftUI surfaces the destructive button more than once in the element
        // tree, so this has to be resolved positionally.
        confirm.buttons["Löschen"].firstMatch.tap()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, tiles.count >= before {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(tiles.count, before - 1, "confirming should remove exactly one app")
    }

    /// A network-capability mini-app must ask the user before it gets internet.
    func testNetworkMiniAppAsksConsent() {
        app.launch()
        startFreshThread()
        sendChatMessage("Bau eine Netz-App")
        let keep = app.buttons["keep-app"]
        XCTAssertTrue(keep.waitForExistence(timeout: 25), "network mini-app card should appear")
        let keptBefore = keptCount
        XCTAssertTrue(tap(keep, untilTrue: { self.keptCount > keptBefore }), "keeping should confirm")

        openAppsTab()
        let item = app.buttons["library-app"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "kept app should be in the library")

        // Consent prompt gates the relaxed (network) capability.
        XCTAssertTrue(tap(item, until: app.alerts.firstMatch),
                      "a network mini-app must prompt for consent")
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
        let solo = app.buttons["new-solo-chat"]
        XCTAssertTrue(tap(compose, until: solo), "new-chat sheet should offer a solo chat")
        XCTAssertTrue(
            tap(solo, until: app.descendants(matching: .any)["chat-input"].firstMatch),
            "creating a chat should push into it"
        )
    }

    /// The keep button relabels itself instead of disappearing, so "Gespeichert"
    /// is what a landed tap looks like — and since every earlier card keeps its
    /// own confirmed button in the transcript, the COUNT is the signal.
    private var keptCount: Int {
        app.buttons.matching(
            NSPredicate(format: "identifier == 'keep-app' AND label CONTAINS 'Gespeichert'")
        ).count
    }

    /// Back out of an open conversation to the list.
    private func backToChatList() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
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
        // The selected tab publishes two elements with the same label, so this
        // is ambiguous whenever the app relaunches already on Apps.
        //
        // The tap is verified rather than fired blind: the launch splash
        // cross-fades out OVER a tab bar that already exists in the tree, so on
        // a cold (freshly installed) launch the first tap here was swallowed
        // and the caller then blamed the Apps tab for not offering add-webapp.
        // add-webapp is the Apps tab's toolbar item, so it is present whether
        // the library is empty or full.
        XCTAssertTrue(
            tap(app.tabBars.buttons["Apps"].firstMatch, until: app.buttons["add-webapp"]),
            "the Apps tab should come up"
        )
    }

    /// Type into the composer and send.
    ///
    /// The tap is verified against real keyboard focus rather than fired blind:
    /// XCUITest snapshots a hit point and only THEN synthesizes the touch, so
    /// anything that intervenes in between (in the 2026-08-09 gate run an
    /// unrelated simulator app took the foreground — the log shows an 11 s
    /// "Wait for com.aiity.haiity to idle" followed by a re-Activate of aiity)
    /// makes the touch land on a stale point. The field then never becomes
    /// first responder and typeText dies with "Neither element nor any
    /// descendant has keyboard focus". Focusing is best-effort and bounded:
    /// a genuine composer regression would still fail on the typeText below.
    private func sendChatMessage(_ text: String) {
        typeText(text, into: "chat-input", in: app)
        // Send is verified too: the 2026-08-09 re-run lost a send tap to
        // "Computed hit point {-1, -1} after scrolling to visible" while
        // XCUITest was busy waiting for an unrelated app on the same simulator
        // ("Wait for de.aiity.lexaiity to idle"). The user's own bubble is the
        // proof the message actually went out.
        let bubble = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(tap(app.buttons["chat-send"], until: bubble),
                      "sending should put the message in the transcript")
    }
}
