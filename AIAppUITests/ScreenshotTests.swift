import XCTest

/// Captures the app's screens as PNGs for the README and the App Store listing.
///
/// A UI test rather than a manual pass for two reasons: it runs against a fresh
/// container every time, so nothing from real use can end up in a public
/// screenshot, and the roster and provider are seeded, so the frames are
/// reproducible instead of depending on whatever the device happened to hold.
///
/// Not part of the normal suite — it asserts almost nothing. Run it on purpose:
///
///   xcodebuild ... -only-testing:AIAppUITests/ScreenshotTests test
///
/// Files land in `AIITY_SHOT_DIR` (default /tmp/aiity-shots).
final class ScreenshotTests: XCTestCase {

    private var shotDirectory: URL {
        let path = ProcessInfo.processInfo.environment["AIITY_SHOT_DIR"] ?? "/tmp/aiity-shots"
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Three agents with a lead, so the Agents tab and any group shows the
    /// shape the app is actually for.
    private static let roster = """
    [
      {"id":"11111111-1111-4111-8111-111111111111","name":"Rechercheur",
       "role":"Nennt die harten Fakten und Zahlen, die für die Entscheidung zählen.",
       "emoji":"🔎","enabled":true,"isLead":false,"presetId":"","model":""},
      {"id":"22222222-2222-4222-8222-222222222222","name":"Kritiker",
       "role":"Sucht die Schwachstelle: falsche Annahme, fehlender Fall, unbegründete Behauptung.",
       "emoji":"🧐","enabled":true,"isLead":false,"presetId":"","model":""},
      {"id":"33333333-3333-4333-8333-333333333333","name":"Leitung",
       "role":"Führt die Beiträge zu einer Entscheidung zusammen und benennt den nächsten Schritt.",
       "emoji":"⭐️","enabled":true,"isLead":true,"presetId":"","model":""}
    ]
    """

    private static let stubProvider = """
    {"presetId":"openai","baseURL":"http://127.0.0.1:8555/v1","model":"stub","searchEndpoint":"http://127.0.0.1:8555"}
    """

    private func launch() -> XCUIApplication {
        let rosterFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("shot-agents.json")
        try? Data(Self.roster.utf8).write(to: rosterFile)

        let app = XCUIApplication()
        app.launchArguments += ["-onboarding.completed.v1", "1"]
        app.launchEnvironment["AIITY_AGENTS_FILE"] = rosterFile.path
        app.launchEnvironment["PROVIDER_SETTINGS_JSON"] = Self.stubProvider
        app.launchEnvironment["AIITY_TEST_API_KEY"] = "stub-key"
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: shotDirectory.appendingPathComponent("\(name).png"))
        // Also attach it, so a CI run keeps them in the result bundle.
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tab(_ app: XCUIApplication, _ label: String) {
        let button = app.tabBars.buttons[label].firstMatch
        if button.waitForExistence(timeout: 5) {
            button.tap()
        } else {
            app.buttons[label].firstMatch.tap()
        }
        sleep(1)
    }

    func testCaptureScreens() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 25))
        sleep(2)
        capture("01-chats")

        tab(app, "Agenten")
        capture("02-agents")

        tab(app, "Apps")
        capture("03-apps")

        tab(app, "Mehr")
        capture("04-more")

        // Back to chat and open a conversation so the composer and the mode
        // selector are visible — that is where the app's idea actually shows.
        tab(app, "Chat")
        let newChat = app.buttons["Neuer Chat"].firstMatch
        if newChat.waitForExistence(timeout: 5) {
            newChat.tap()
        } else {
            app.buttons["chat-new"].firstMatch.tap()
        }
        sleep(2)
        capture("05-conversation")

        let input = app.textFields["chat-input"].firstMatch
        if input.waitForExistence(timeout: 8) {
            input.tap()
            input.typeText("Bau mir einen Timer für Intervalltraining")
            sleep(1)
            capture("06-composer")
        }

        print("AIITY-SHOTS \(shotDirectory.path)")
    }
}
