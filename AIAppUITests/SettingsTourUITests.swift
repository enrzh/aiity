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

        // Providers live behind the "Mehr" tab → "KI-Anbieter & Modelle".
        app.tabBars.buttons["Mehr"].tap()
        let connectionsRow = app.buttons["open-connections"]
        XCTAssertTrue(connectionsRow.waitForExistence(timeout: 10), "Settings should offer the KI-Anbieter row")
        connectionsRow.tap()
        XCTAssertTrue(app.navigationBars["Anbieter"].waitForExistence(timeout: 10))
        attach(app, name: "connections-list")

        // OpenRouter (Schnellstart) detail -> OAuth add-account button must appear.
        let openRouterRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'OpenRouter'")).firstMatch
        scrollTo(openRouterRow, in: app)
        XCTAssertTrue(openRouterRow.waitForExistence(timeout: 10), "provider list should include OpenRouter")
        openRouterRow.tap()
        let oauthButton = app.buttons["oauth-add-account"]
        XCTAssertTrue(oauthButton.waitForExistence(timeout: 10), "OAuth add-account button should appear for OpenRouter")
        attach(app, name: "connections-openrouter")

        // Back to the list, then xAI (Grok) also exposes the subscription OAuth button.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let xaiRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'xAI'")).firstMatch
        scrollTo(xaiRow, in: app)
        XCTAssertTrue(xaiRow.waitForExistence(timeout: 10), "provider list should include xAI (Grok)")
        xaiRow.tap()
        XCTAssertTrue(app.buttons["oauth-add-account"].waitForExistence(timeout: 10),
                      "OAuth add-account button should appear for Grok")
        attach(app, name: "connections-xai")

        // Skills tab lists the built-ins.
        app.tabBars.buttons["Skills"].tap()
        XCTAssertTrue(app.staticTexts["UI-Design Pro"].waitForExistence(timeout: 10), "builtin skills should be listed")
        attach(app, name: "skills")
    }

    /// Visual tour of the navbar (Chat/Apps/Skills/Mehr) for review screenshots.
    func testAppTour() {
        let app = makeApp()
        app.launch()

        // Chat is the default tab (chat-input is a text field).
        XCTAssertTrue(app.descendants(matching: .any)["chat-input"].firstMatch.waitForExistence(timeout: 10))
        attach(app, name: "tour-1-chat")

        app.tabBars.buttons["Apps"].tap()
        attach(app, name: "tour-2-apps")

        app.tabBars.buttons["Skills"].tap()
        attach(app, name: "tour-3-skills")

        app.tabBars.buttons["Mehr"].tap()
        attach(app, name: "tour-4-mehr")

        app.buttons["open-connections"].tap()
        XCTAssertTrue(app.navigationBars["Anbieter"].waitForExistence(timeout: 10))
        attach(app, name: "tour-5-anbieter")
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
