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
      {"id":"11111111-1111-4111-8111-111111111111","name":"Researcher",
       "role":"States the hard facts and numbers that matter for the decision.",
       "emoji":"🔎","enabled":true,"isLead":false,"presetId":"","model":""},
      {"id":"22222222-2222-4222-8222-222222222222","name":"Critic",
       "role":"Finds the weak point: a wrong assumption, a missing case, an unfounded claim.",
       "emoji":"🧐","enabled":true,"isLead":false,"presetId":"","model":""},
      {"id":"33333333-3333-4333-8333-333333333333","name":"Lead",
       "role":"Pulls the contributions into a decision and names the next step.",
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
        // Force the interface language so the frames are reproducible rather
        // than depending on the simulator's setting. AIITY_SHOT_LANG=fr etc.
        let language = ProcessInfo.processInfo.environment["AIITY_SHOT_LANG"] ?? "en"
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
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

    /// Tab titles are localised now; index by position instead of by word.
    private var tabLabels: [String] {
        ProcessInfo.processInfo.environment["AIITY_SHOT_LANG"] == "de"
            ? ["Agenten", "Apps", "Mehr", "Chat"]
            : ["Agents", "Apps", "More", "Chat"]
    }

    func testCaptureScreens() {
        let app = launch()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 25))
        sleep(2)
        capture("01-chats")

        tab(app, tabLabels[0])
        capture("02-agents")

        tab(app, tabLabels[1])
        capture("03-apps")

        tab(app, tabLabels[2])
        capture("04-more")

        // Back to chat and open a conversation so the composer and the mode
        // selector are visible — that is where the app's idea actually shows.
        tab(app, tabLabels[3])
        // Opening a conversation is two taps: compose, then pick solo.
        // Identifiers, not labels — the labels are localised now.
        let compose = app.descendants(matching: .any).matching(identifier: "new-chat").firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "no compose button")
        compose.tap()
        let solo = app.descendants(matching: .any).matching(identifier: "new-solo-chat").firstMatch
        XCTAssertTrue(solo.waitForExistence(timeout: 10), "no solo option")
        solo.tap()

        // `TextField(axis: .vertical)` is backed by a TEXT VIEW, so
        // app.textFields["chat-input"] never matched and this frame was
        // silently skipped on every previous run. Match the identifier alone.
        let input = app.descendants(matching: .any).matching(identifier: "chat-input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15), "no composer")
        sleep(1)
        capture("05-conversation")

        input.tap()
        input.typeText("Build me a timer for interval training")
        sleep(1)
        capture("06-composer")

        print("AIITY-SHOTS \(shotDirectory.path)")
    }
}
