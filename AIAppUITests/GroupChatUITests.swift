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

        createAgent(named: "Planer", role: "Plant Schritte und Reihenfolge.")
        createAgent(named: "Kritiker", role: "Sucht Schwachstellen in Plänen.")

        // Start a group with both of them.
        app.tabBars.buttons["Chat"].firstMatch.tap()
        _ = app.buttons["new-chat"].waitForExistence(timeout: 10)
        let compose = app.buttons["new-chat"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        compose.tap()

        let options = app.buttons.matching(identifier: "group-agent-option")
        XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 10), "both agents should be selectable")
        XCTAssertGreaterThanOrEqual(options.count, 2)
        options.element(boundBy: 0).tap()
        options.element(boundBy: 1).tap()
        app.buttons["start-group-chat"].tap()

        // One message from the user…
        let input = app.descendants(matching: .any)["chat-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15), "the group chat should open")
        input.tap()
        input.typeText("Wie gehen wir das an?")
        app.buttons["chat-send"].tap()

        // …and both agents answer, each labelled with its own name.
        let planner = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Planer'")
        ).firstMatch
        XCTAssertTrue(planner.waitForExistence(timeout: 40), "the first agent should speak, attributed")

        let critic = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Kritiker'")
        ).firstMatch
        XCTAssertTrue(critic.waitForExistence(timeout: 40), "the second agent should speak too")

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
