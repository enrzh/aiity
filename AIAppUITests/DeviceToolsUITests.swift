import XCTest

/// The device-data tools, driven the way a user drives them, against
/// tools/stub_llm_server.py (port 8555): grant the permission in Settings, ask
/// for a calendar entry, and land on the confirmation sheet.
///
/// This is the half that unit tests structurally cannot reach — the real TCC
/// dialog, the real `UIAlertController`, and a real `EKEventStore.save` on the
/// simulator's own calendar database.
///
/// Not hermetic: the calendar permission is remembered per simulator device
/// (`xcrun simctl privacy <device> reset calendar com.aiity.app` puts it back),
/// so this is a "run it to verify" suite, not a CI gate.
final class DeviceToolsUITests: XCTestCase {

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

    func testGrantCalendarThenCreateAnEventThroughTheConfirmationSheet() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_DEVICE_TOOL_TESTS"] == "1",
            "Drives the real EventKit permission (device state); run with RUN_DEVICE_TOOL_TESTS=1"
        )
        app.launch()
        dismissCrashNoticeIfShown(in: app)

        // 1. The permission is granted from a foreground tap in Settings — the
        //    only place in the app that can ask for it.
        app.tabBars.buttons["Mehr"].firstMatch.tap()
        let row = app.buttons["open-agent-tools"]
        if !row.waitForExistence(timeout: 10) {
            print("SETTINGS HIERARCHY >>>\n\(app.debugDescription)\n<<< END")
            XCTFail("Mehr should offer Agent-Werkzeuge")
        }
        row.tap()

        let allowWrite = app.buttons["allow-calendar-write"]
        if allowWrite.waitForExistence(timeout: 5) {
            allowWrite.tap()
            tapSystemAllow()
        }
        XCTAssertTrue(
            app.staticTexts["Nur eintragen"].waitForExistence(timeout: 10)
                || app.staticTexts["Eintragen und lesen"].waitForExistence(timeout: 2),
            "the calendar row should report the granted level"
        )

        // 2. Ask for the entry. The stub answers with a create_calendar_event
        //    tool call carrying a concrete payload.
        app.tabBars.buttons["Chat"].firstMatch.tap()
        startFreshThread()
        sendChatMessage("Trag den Termin ein")

        // 3. The write must stop at a confirmation showing the actual content.
        let sheet = app.alerts.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 25), "a write must ask before it happens")
        XCTAssertTrue(sheet.staticTexts.element(boundBy: 1).label.contains("Zahnarzt"),
                      "the sheet must show the concrete payload, not a category")
        sheet.buttons["Eintragen"].tap()

        // 4. Only now does the event exist.
        let confirmation = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'eingetragen'")).firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 20), "the tool should report a real save")

        // 5. The other half of the gate, in the same run so the permission
        //    state is known: Abbrechen writes nothing.
        backToChatList()
        dismissCrashNoticeIfShown(in: app)
        startFreshThread()
        sendChatMessage("Trag den Termin ein")
        let second = app.alerts.firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 25), "the second write must ask too")
        second.buttons["Abbrechen"].tap()
        let declined = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'eingetragen'")).firstMatch
        XCTAssertFalse(declined.waitForExistence(timeout: 8), "cancelling must not create anything")
    }

    private func backToChatList() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
    }

    // `dismissCrashNoticeIfShown(in:)` lives in UITestSupport.swift now.

    // MARK: - Helpers

    /// The TCC dialog belongs to SpringBoard, not to the app, and its wording
    /// follows the SIMULATOR's language rather than the app's.
    private func tapSystemAllow() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            for button in springboard.alerts.buttons.allElementsBoundByIndex {
                let label = button.label.lowercased()
                // "Nicht erlauben" / "Don't Allow" also contain the allow word —
                // matching loosely here declines the permission and then fails
                // one assertion later, looking like a bug in the app.
                guard !label.contains("nicht"), !label.contains("don") else { continue }
                if label.contains("erlaub") || label.contains("allow") {
                    button.tap()
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    private func startFreshThread() {
        let compose = app.buttons["new-chat"]
        XCTAssertTrue(compose.waitForExistence(timeout: 15))
        compose.tap()
        let solo = app.buttons["new-solo-chat"]
        XCTAssertTrue(solo.waitForExistence(timeout: 10))
        solo.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-input"].firstMatch.waitForExistence(timeout: 15))
    }

    private func sendChatMessage(_ text: String) {
        let input = app.descendants(matching: .any)["chat-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText(text)
        app.buttons["chat-send"].tap()
    }
}
