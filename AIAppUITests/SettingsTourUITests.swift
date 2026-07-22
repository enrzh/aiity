import XCTest

/// Smoke test of the connections surface: providers now open from Settings →
/// "KI-Anbieter"; a provider's detail exposes its OAuth add-account button. The
/// app tour screenshots every navbar surface + chat + the on-device model list.
final class SettingsTourUITests: XCTestCase {

    func testSettingsTour() {
        let app = XCUIApplication()
        app.launch()

        // Providers now live behind Settings → "KI-Anbieter".
        app.tabBars.buttons["Einstellungen"].tap()
        let connectionsRow = app.buttons["open-connections"]
        XCTAssertTrue(connectionsRow.waitForExistence(timeout: 10), "Settings should offer the KI-Anbieter row")
        connectionsRow.tap()
        XCTAssertTrue(app.navigationBars["Anbieter"].waitForExistence(timeout: 10))
        attach(app, name: "connections-list")

        // OpenRouter detail -> OAuth add-account button must appear.
        let openRouterRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'OpenRouter'")).firstMatch
        scrollTo(openRouterRow, in: app)
        XCTAssertTrue(openRouterRow.waitForExistence(timeout: 10), "provider list should include OpenRouter")
        openRouterRow.tap()
        let oauthButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'hinzufügen'")).firstMatch
        XCTAssertTrue(oauthButton.waitForExistence(timeout: 10), "OAuth add-account button should appear for OpenRouter")
        attach(app, name: "connections-openrouter")

        // Back to the list, then xAI (Grok) also exposes the subscription OAuth button.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let xaiRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Grok'")).firstMatch
        scrollTo(xaiRow, in: app)
        XCTAssertTrue(xaiRow.waitForExistence(timeout: 10), "provider list should include xAI (Grok)")
        xaiRow.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'hinzufügen'")).firstMatch.waitForExistence(timeout: 10),
                      "OAuth add-account button should appear for Grok")
        attach(app, name: "connections-xai")

        // Skills tab lists the built-ins.
        app.tabBars.buttons["Skills"].tap()
        XCTAssertTrue(app.staticTexts["UI-Design Pro"].waitForExistence(timeout: 10), "builtin skills should be listed")
        XCTAssertTrue(app.staticTexts["Spiele-Entwickler"].exists)
        XCTAssertTrue(app.staticTexts["Diagramme & Charts"].exists)
        attach(app, name: "skills")
    }

    /// Visual tour of the navbar (Apps/Skills/Einstellungen) + the chat cover +
    /// the on-device model list, for review screenshots on a device-hub sim.
    func testAppTour() {
        let app = XCUIApplication()
        app.launch()

        // Apps page: Chat is a permanent app card here.
        XCTAssertTrue(app.buttons["open-chat"].waitForExistence(timeout: 10))
        attach(app, name: "tour-1-apps")

        // Open the chat cover, then close it.
        app.buttons["open-chat"].tap()
        _ = app.buttons["chat-new"].waitForExistence(timeout: 8)
        attach(app, name: "tour-2-chat")
        app.buttons["chat-close"].tap()

        app.tabBars.buttons["Skills"].tap()
        attach(app, name: "tour-3-skills")

        app.tabBars.buttons["Einstellungen"].tap()
        attach(app, name: "tour-4-settings")

        // Settings -> KI-Anbieter -> on-device models.
        app.buttons["open-connections"].tap()
        XCTAssertTrue(app.navigationBars["Anbieter"].waitForExistence(timeout: 10))
        attach(app, name: "tour-5-anbieter")

        let mlxRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Lokal auf dem Gerät'")).firstMatch
        scrollTo(mlxRow, in: app)
        if mlxRow.exists {
            mlxRow.tap()
            _ = app.staticTexts["Gemma 3 1B (Google)"].waitForExistence(timeout: 8)
            attach(app, name: "tour-6-local-models")
        }
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
        // Simulator test runners are host processes: also drop the shot on
        // disk for review workflows outside Xcode.
        let directory = URL(fileURLWithPath: "/tmp/aiapp-tour", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
