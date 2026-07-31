import XCTest

/// End-to-end proof that a group chat is a real conversation and not just a
/// room with names on the door: create two agents, start a group with both,
/// send one message, and require two attributed replies.
final class GroupChatUITests: XCTestCase {

    private var app: XCUIApplication!

    private static let stubSettings = """
    {"presetId":"openai","baseURL":"http://127.0.0.1:8555/v1","model":"stub","searchEndpoint":"http://127.0.0.1:8555"}
    """

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PROVIDER_SETTINGS_JSON"] = Self.stubSettings
        app.launchEnvironment["AIITY_TEST_API_KEY"] = "stub-key"
        app.launchArguments += ["-onboarding.completed.v1", "1"]
    }

    func testGroupChatLetsEveryAgentSpeak() {
        app.launch()

        // Unique per run: agents.json persists in the simulator container, so
        // fixed names accumulated duplicates across runs and the test ended up
        // selecting two DIFFERENT agents that were both called "Planer" —
        // reporting "the second agent never spoke" when it had.
        let run = UUID().uuidString.prefix(4)
        let first = "Planer\(run)"
        let second = "Kritiker\(run)"
        createAgent(named: first, role: "Plant Schritte und Reihenfolge.")
        createAgent(named: second, role: "Sucht Schwachstellen in Plänen.")

        // Start a group with both of them.
        app.tabBars.buttons["Chat"].firstMatch.tap()
        _ = app.buttons["new-chat"].waitForExistence(timeout: 10)
        let compose = app.buttons["new-chat"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
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

        // Another round is available and explicit — never automatic.
        XCTAssertTrue(
            app.buttons["continue-group"].waitForExistence(timeout: 20),
            "a group chat should offer another round rather than looping by itself"
        )
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
