import XCTest

/// App Store screenshots.
///
/// Separate from `ScreenshotTests` (which documents the app for the README)
/// because the store needs different things: exact device sizes, a conversation
/// that shows the product's actual point rather than an empty state, and a real
/// provider name — "stub" in a listing looks like a bug.
///
/// What is real and what is staged, so nobody is misled later: the app, the
/// interface, the sandbox and the rendered mini-app are all genuine. The
/// model's side of the conversation is served by `tools/stub_llm_server.py` in
/// `STUB_SCRIPT=screenshot` mode, so the frames are identical on every run and
/// producing them costs no API credits. The provider and model names shown are
/// ones the app genuinely supports.
///
///   python3 tools/stub_llm_server.py 8555 &   # with STUB_SCRIPT=screenshot
///   xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
///     -resultBundlePath /tmp/store.xcresult \
///     -only-testing:AIAppUITests/AppStoreScreenshotTests test
final class AppStoreScreenshotTests: XCTestCase {

    /// A provider and model the app really supports. Shown in the agent rows
    /// and the model chip, so it must not say "stub".
    private static let provider = """
    {"presetId":"openai","baseURL":"http://127.0.0.1:8555/v1","model":"gpt-4o","searchEndpoint":"http://127.0.0.1:8555"}
    """

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

    private var shotDirectory: URL {
        let path = ProcessInfo.processInfo.environment["AIITY_SHOT_DIR"] ?? "/tmp/aiity-store"
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        try? shot.pngRepresentation.write(to: shotDirectory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// SwiftUI decides the element TYPE, and it is not what you would guess:
    /// `TextField(axis: .vertical)` is backed by a text view, so
    /// `app.textFields["chat-input"]` matches nothing. Match on the identifier
    /// alone. This is why the earlier passes silently produced no composer
    /// frame — the lookup could never have succeeded.
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Opening a conversation is TWO taps: the compose button opens a sheet
    /// where you choose solo or group, then you pick one.
    @discardableResult
    private func openSoloConversation(_ app: XCUIApplication) -> Bool {
        let compose = element(app, "new-chat")
        guard compose.waitForExistence(timeout: 10) else { return false }
        compose.tap()
        let solo = element(app, "new-solo-chat")
        guard solo.waitForExistence(timeout: 10) else { return false }
        solo.tap()
        return element(app, "chat-input").waitForExistence(timeout: 15)
    }

    func testCaptureStoreScreens() {
        let rosterFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-agents.json")
        try? Data(Self.roster.utf8).write(to: rosterFile)

        let app = XCUIApplication()
        let language = ProcessInfo.processInfo.environment["AIITY_SHOT_LANG"] ?? "en"
        app.launchArguments += [
            "-onboarding.completed.v1", "1",
            "-AppleLanguages", "(\(language))", "-AppleLocale", language,
            // Dark is the app's own look and what the listing should show.
            "-prefs.appearance.v1", "dark",
        ]
        app.launchEnvironment["AIITY_AGENTS_FILE"] = rosterFile.path
        app.launchEnvironment["PROVIDER_SETTINGS_JSON"] = Self.provider
        app.launchEnvironment["AIITY_TEST_API_KEY"] = "screenshot-key"
        app.launch()

        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 30))
        sleep(2)

        // 1 — a real conversation that produces a mini-app. This is the
        // product's whole idea, so it leads.
        XCTAssertTrue(openSoloConversation(app), "could not open a conversation")
        sleep(1)

        let input = element(app, "chat-input")
        input.tap()
        input.typeText("Build me an interval timer: 40 seconds on, 20 off, 8 rounds")
        element(app, "chat-send").tap()

        // The answer streams and the mini-app card appears under the header.
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'preview' OR label CONTAINS[c] 'vorschau'")).firstMatch
        _ = card.waitForExistence(timeout: 40)
        sleep(3)

        // The keyboard stays up after sending and covers half the frame, and
        // the floating card overlaps the top of the answer. Dismiss one and
        // scroll the other clear before capturing.
        if app.keyboards.element.exists {
            app.swipeDown()
            sleep(1)
        }
        app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        sleep(2)
        capture("01-conversation")

        // 2 — the mini-app actually running in its sandbox.
        if card.exists {
            card.tap()
            // The mini-app is a WKWebView, and a fixed sleep here raced its
            // load: the store frame came out as an empty sheet with only the
            // title bar. Wait for the web content itself to reach the
            // accessibility tree — locale-independent, unlike matching text.
            let web = app.webViews.firstMatch
            _ = web.waitForExistence(timeout: 30)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline && web.staticTexts.count == 0 {
                usleep(300_000)
            }
            sleep(1)
            capture("02-miniapp")
            // Back out of the preview however this build presents it.
            let done = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'done' OR label CONTAINS[c] 'close' OR label CONTAINS[c] 'fertig'")
            ).firstMatch
            if done.exists { done.tap() } else { app.swipeDown() }
            sleep(2)

            // Keep it. Without this the Apps tab below photographs its own
            // empty state — "No apps yet" is a poor advertisement for the one
            // feature the frame exists to show.
            let keep = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'keep' OR label CONTAINS[c] 'behalten'")
            ).firstMatch
            if keep.waitForExistence(timeout: 10) {
                keep.tap()
                sleep(3)
            }
        }

        // 3 — the agents, with a real model name under each.
        app.tabBars.buttons.element(boundBy: 2).tap()
        sleep(2)
        capture("03-agents")

        // 4 — the saved mini-apps.
        app.tabBars.buttons.element(boundBy: 1).tap()
        sleep(2)
        capture("04-apps")

        // 5 — bring-your-own-provider, the other half of the pitch.
        app.tabBars.buttons.element(boundBy: 3).tap()
        sleep(2)
        capture("05-settings")

        print("AIITY-STORE-SHOTS \(shotDirectory.path)")
    }
}
