import XCTest

/// Smoke test of the connections surface: providers open from the "Mehr" tab →
/// "KI-Anbieter & Modelle"; a provider's detail exposes its OAuth add-account
/// button. The app tour screenshots every navbar surface. Onboarding is skipped
/// via a launch argument.
final class SettingsTourUITests: XCTestCase {

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboarding.completed.v1", "1"]
        return app
    }

    func testSettingsTour() {
        let app = makeApp()
        app.launch()

        // A previous run's terminate() makes the crash notice slide in over the
        // chat list; clear it before touching anything underneath.
        dismissCrashNoticeIfShown(in: app)

        // Providers live behind the "Mehr" tab → "KI-Anbieter & Modelle".
        // The selected tab publishes two elements with the same label, so this
        // must resolve positionally — every other UI suite already does.
        //
        // tap(_:until:) rather than a bare tap(): the tab bar EXISTS while the
        // launch splash is still cross-fading over it, so the first tap used to
        // be swallowed ({-1,-1} hit point) and the test then waited 10 s for a
        // row on a screen that was still Chat. See UITestSupport.
        XCTAssertTrue(waitForTabBar(app), "tab bar should come up after the splash")
        let connectionsRow = app.buttons["open-connections"]
        XCTAssertTrue(tap(app.tabBars.buttons["Mehr"].firstMatch, until: connectionsRow),
                      "Settings should offer the KI-Anbieter row")
        XCTAssertTrue(tap(connectionsRow, until: app.navigationBars["Anbieter"]),
                      "KI-Anbieter should open the provider list")
        attach(app, name: "connections-list")

        // OpenRouter (Schnellstart) detail -> OAuth add-account button must appear.
        let openRouterRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'OpenRouter'")).firstMatch
        scrollTo(openRouterRow, in: app)
        XCTAssertTrue(openRouterRow.waitForExistence(timeout: 10), "provider list should include OpenRouter")
        let oauthButton = app.buttons["oauth-add-account"]
        XCTAssertTrue(tap(openRouterRow, until: oauthButton),
                      "OAuth add-account button should appear for OpenRouter")
        attach(app, name: "connections-openrouter")

        // Back to the list, then Anthropic (Claude) exposes the subscription OAuth
        // button (OpenAI/Grok deliberately do not — dead-end without impersonation).
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Anbieter"].waitForExistence(timeout: 10),
                      "back should return to the provider list")
        // The pushed form and the list coexist for the length of the pop
        // animation, so the OpenRouter OAuth button can still be in the tree.
        // Waiting it out keeps the Anthropic step below from "passing" on the
        // button that is really OpenRouter's.
        XCTAssertTrue(waitFor(timeout: 5) { !oauthButton.exists },
                      "the provider form should be gone after popping back")
        let claudeRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Anthropic'")).firstMatch
        scrollTo(claudeRow, in: app)
        XCTAssertTrue(claudeRow.waitForExistence(timeout: 10), "provider list should include Anthropic (Claude)")
        XCTAssertTrue(tap(claudeRow, until: app.buttons["oauth-add-account"]),
                      "OAuth add-account button should appear for Claude")
        attach(app, name: "connections-claude")

        // Skills lives in More so the primary tab bar stays focused.
        // The selected tab publishes two elements with the same label, so this
        // must resolve positionally — every other UI suite already does.
        let skillsRow = app.buttons["open-skills"]
        XCTAssertTrue(tap(app.tabBars.buttons["Mehr"].firstMatch, until: skillsRow),
                      "Mehr should offer the Skills row")
        XCTAssertTrue(tap(skillsRow, until: app.staticTexts["UI-Design Pro"]),
                      "builtin skills should be listed")
        attach(app, name: "skills")
    }

    /// Visual tour of every tab (Chat/Apps/Agenten/Mehr) for review screenshots.
    func testAppTour() {
        let app = makeApp()
        app.launch()

        // The Chat tab opens the conversation LIST now, not a conversation —
        // the compose button is what proves we are on it.
        XCTAssertTrue(app.buttons["new-chat"].waitForExistence(timeout: 10),
                      "the Chat tab should open the conversation list")
        attach(app, name: "tour-1-chats")

        XCTAssertTrue(tap(app.tabBars.buttons["Apps"].firstMatch, until: app.buttons["add-webapp"]),
                      "the Apps tab should come up")
        attach(app, name: "tour-2-apps")

        XCTAssertTrue(tap(app.tabBars.buttons["Agenten"].firstMatch, until: app.buttons["add-agent"]),
                      "the Agenten tab should come up")
        attach(app, name: "tour-3-agenten")

        // The selected tab publishes two elements with the same label, so this
        // must resolve positionally — every other UI suite already does.
        let connectionsRow = app.buttons["open-connections"]
        XCTAssertTrue(tap(app.tabBars.buttons["Mehr"].firstMatch, until: connectionsRow),
                      "the Mehr tab should come up")
        attach(app, name: "tour-4-mehr")

        XCTAssertTrue(tap(connectionsRow, until: app.navigationBars["Anbieter"]),
                      "KI-Anbieter should open the provider list")
        attach(app, name: "tour-5-anbieter")
    }

    /// The on-device model list is the screen that shipped the crash: it
    /// offered 14B/32B/70B models to every phone with nothing but a prose hint
    /// in the subtitle, and an OOM kill leaves no crash report to trace it by.
    ///
    /// Note what this can and cannot check. The SIMULATOR REPORTS THE HOST
    /// MAC'S MEMORY, so the per-device gate ("this row is blocked on YOUR
    /// phone") cannot be reproduced here at all — that half is unit-tested
    /// against injected budgets. What IS device-independent, and therefore
    /// checkable here, is the catalog filter: models no iPhone can run are
    /// removed by a fixed constant, not by reading this machine.
    func testTheOnDeviceModelListNamesTheMemoryBudgetAndHidesTheImpossibleModels() {
        let app = makeApp()
        app.launch()
        dismissCrashNoticeIfShown(in: app)

        XCTAssertTrue(waitForTabBar(app), "tab bar should come up after the splash")
        let connectionsRow = app.buttons["open-connections"]
        XCTAssertTrue(tap(app.tabBars.buttons["Mehr"].firstMatch, until: connectionsRow),
                      "Settings should offer the KI-Anbieter row")
        XCTAssertTrue(tap(connectionsRow, until: app.navigationBars["Anbieter"]),
                      "KI-Anbieter should open the provider list")

        let mlxRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'MLX'")).firstMatch
        scrollTo(mlxRow, in: app)
        XCTAssertTrue(mlxRow.waitForExistence(timeout: 10), "provider list should include on-device MLX")
        // The device's real capacity, said out loud — the old screen said
        // nothing about memory anywhere, on any row.
        let memoryNote = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'gibt einer App'")
        ).firstMatch
        XCTAssertTrue(tap(mlxRow, until: memoryNote),
                      "the on-device model list must name what this phone allows an app")
        attach(app, name: "connections-mlx-models")

        // One pass down the whole list: the models that no iPhone can run must
        // never appear, not even greyed out.
        let impossible = ["70B", "32B", "14B", "27B"]
        var found: Set<String> = []
        func noteWhatIsOnScreen() {
            for name in impossible {
                let predicate = NSPredicate(format: "label CONTAINS %@", name)
                if app.staticTexts.matching(predicate).firstMatch.exists
                    || app.buttons.matching(predicate).firstMatch.exists {
                    found.insert(name)
                }
            }
        }
        noteWhatIsOnScreen()
        for _ in 0..<12 {
            app.swipeUp()
            noteWhatIsOnScreen()
        }
        XCTAssertTrue(
            found.isEmpty,
            "\(found.sorted()) cannot run on any supported iPhone and must not be offered"
        )
    }

    /// Swipes up until the element exists (lazy List rows materialize only
    /// when scrolled near the viewport).
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        var swipes = 0
        while !element.exists && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: "/tmp/aiapp-tour", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
