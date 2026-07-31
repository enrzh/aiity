import XCTest

/// End-to-end proof that a group chat is a real conversation and not just a
/// room with names on the door: create two agents, start a group with both,
/// send one message, and require two attributed replies.
final class GroupChatUITests: XCTestCase {

    private var app: XCUIApplication!

    private static let stubSettings = """
    {"presetId":"openai","baseURL":"http://127.0.0.1:8555/v1","model":"stub","searchEndpoint":"http://127.0.0.1:8555"}
    """

    /// Write the screen to disk whenever this test fails. Three attempts were
    /// spent theorising about which screen was showing; a screenshot answers it.
    override func tearDown() {
        guard let run = testRun, run.failureCount > 0 else { return }
        let shot = XCUIScreen.main.screenshot()
        let dir = URL(fileURLWithPath: "/tmp/aiapp-tour", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: dir.appendingPathComponent("group-fail.png"))
    }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PROVIDER_SETTINGS_JSON"] = Self.stubSettings
        app.launchEnvironment["AIITY_TEST_API_KEY"] = "stub-key"
        app.launchArguments += ["-onboarding.completed.v1", "1"]
        // Fresh agent roster per run, so the test selects from exactly the two
        // agents it creates rather than everything earlier runs left behind.
        app.launchEnvironment["AIITY_AGENTS_FILE"] =
            NSTemporaryDirectory() + "aiity-agents-\(UUID().uuidString).json"
    }

    func testGroupChatLetsEveryAgentSpeak() {
        app.launch()

        // Unique per run: agents.json persists in the simulator container, so
        // fixed names accumulated duplicates across runs and the test ended up
        // selecting two DIFFERENT agents that were both called "Planer" —
        // reporting "the second agent never spoke" when it had.
        let first = "Planer"
        let second = "Kritiker"
        createAgent(named: first, role: "Plant Schritte und Reihenfolge.")
        createAgent(named: second, role: "Sucht Schwachstellen in Plänen.")

        // Start a group with both of them.
        let compose = openChatList()
        compose.tap()

        // Select BY NAME, not by index: the roster contains agents from earlier
        // runs, so positional taps pick arbitrary ones.
        let firstOption = app.buttons.matching(
            NSPredicate(format: "identifier == 'group-agent-option' AND label CONTAINS %@", first)
        ).firstMatch
        XCTAssertTrue(firstOption.waitForExistence(timeout: 10), "the first agent should be selectable")
        firstOption.tap()

        let secondOption = app.buttons.matching(
            NSPredicate(format: "identifier == 'group-agent-option' AND label CONTAINS %@", second)
        ).firstMatch
        XCTAssertTrue(secondOption.waitForExistence(timeout: 10), "the second agent should be selectable")
        secondOption.tap()
        app.buttons["start-group-chat"].tap()

        // One message from the user…
        let input = app.descendants(matching: .any)["chat-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15), "the group chat should open")
        input.tap()
        input.typeText("Wie gehen wir das an?")
        app.buttons["chat-send"].tap()

        // …and both agents answer, each labelled with its own name.
        let planner = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", first)
        ).firstMatch
        XCTAssertTrue(planner.waitForExistence(timeout: 60), "the first agent should speak, attributed")

        let critic = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", second)
        ).firstMatch
        XCTAssertTrue(critic.waitForExistence(timeout: 60), "the second agent should speak too")

        // The default mode is Automatisch, which continues the discussion by
        // itself — so the manual "keep talking" button must NOT be offered
        // there. (In Nachfragen/Nur planen it is; that is the whole difference.)
        XCTAssertFalse(
            app.buttons["continue-group"].exists,
            "auto mode continues on its own, so the manual round button is redundant"
        )
    }

    /// Reach the conversation LIST and return its compose button.
    ///
    /// The Chat tab can come up already pushed into a conversation (the session
    /// restores an open thread), in which case the compose button lives one
    /// level up and the test would wait for something that is not on screen.
    @discardableResult
    private func openChatList() -> XCUIElement {
        app.tabBars.buttons["Chat"].firstMatch.tap()
        let compose = app.buttons["new-chat"]
        if compose.waitForExistence(timeout: 5) { return compose }

        // Pushed into a chat — pop back to the list.
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        XCTAssertTrue(
            compose.waitForExistence(timeout: 10),
            "the Chat tab should show the conversation list with a compose button"
        )
        return compose
    }

    private func createAgent(named name: String, role: String) {
        // The launch splash holds the UI back for a beat, so the tab bar is not
        // present the instant the app is launched.
        let agentsTab = app.tabBars.buttons["Agenten"].firstMatch
        XCTAssertTrue(agentsTab.waitForExistence(timeout: 15), "tab bar should appear after the splash")
        agentsTab.tap()

        let add = app.buttons["add-agent"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the Agenten tab should offer a add button")
        add.tap()

        let nameField = app.textFields["agent-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "agent editor should open")
        nameField.tap()
        nameField.typeText(name)

        let roleField = app.textViews["agent-role"].exists
            ? app.textViews["agent-role"]
            : app.textFields["agent-role"]
        roleField.tap()
        roleField.typeText(role)

        app.buttons["agent-save"].tap()
        XCTAssertTrue(
            app.buttons.matching(identifier: "agent-row").firstMatch.waitForExistence(timeout: 10),
            "the saved agent should be listed"
        )
    }
}
