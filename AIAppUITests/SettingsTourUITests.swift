import XCTest

/// Smoke test of the settings surface: provider switch shows the OAuth
/// button for OpenRouter, and the skills screen lists the built-ins.
/// Screenshots are attached for visual review.
final class SettingsTourUITests: XCTestCase {

    func testSettingsTour() {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Einstellungen"].tap()
        XCTAssertTrue(app.staticTexts["KI-Anbieter"].waitForExistence(timeout: 10))
        attach(app, name: "settings-default")

        // Switch provider to OpenRouter -> OAuth button must appear.
        let providerRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Anbieter'")).firstMatch
        XCTAssertTrue(providerRow.waitForExistence(timeout: 10), "provider picker row should exist")
        providerRow.tap()
        let openRouterOption = app.buttons["OpenRouter (alle Modelle)"]
        XCTAssertTrue(openRouterOption.waitForExistence(timeout: 10), "picker should list OpenRouter")
        openRouterOption.tap()
        let oauthButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'anmelden'")).firstMatch
        XCTAssertTrue(oauthButton.waitForExistence(timeout: 10), "OAuth sign-in button should appear for OpenRouter")
        attach(app, name: "settings-openrouter")

        // Anthropic: "Sign in with Claude" + client-id field (standard PKCE).
        providerRow.tap()
        let anthropicOption = app.buttons["Anthropic (Claude)"]
        XCTAssertTrue(anthropicOption.waitForExistence(timeout: 10), "picker should list Anthropic")
        anthropicOption.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'anmelden'")).firstMatch.waitForExistence(timeout: 10),
                      "Sign in with Claude button should appear for Anthropic")
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value CONTAINS 'Client-ID' OR placeholderValue CONTAINS 'Client-ID'")).firstMatch.exists,
                      "Anthropic OAuth should expose the client-id field")
        attach(app, name: "settings-anthropic")

        // Skills tab lists the built-ins.
        app.tabBars.buttons["Skills"].tap()
        XCTAssertTrue(app.staticTexts["UI-Design Pro"].waitForExistence(timeout: 10), "builtin skills should be listed")
        XCTAssertTrue(app.staticTexts["Spiele-Entwickler"].exists)
        XCTAssertTrue(app.staticTexts["Diagramme & Charts"].exists)
        attach(app, name: "skills")
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
