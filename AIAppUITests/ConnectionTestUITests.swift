import XCTest

/// TIER 3 — UI wiring of the in-app connection test ("Verbindung testen")
/// against the local stub (tools/stub_llm_server.py, port 8555 — the same
/// instance FullFlowUITests uses; default STUB_MODE serves GET /v1/models and
/// the non-stream probe chat).
///
/// Contract under test (model-autoselect rework): a green probe is a
/// DIAGNOSIS, not a configuration. The probe and "Modelle laden" only SUGGEST
/// a model (a highlighted picker recommendation); nothing is committed until
/// the user picks explicitly — so the exit prompt ("Kein Modell gewählt")
/// must still intercept back navigation after a successful probe.
final class ConnectionTestUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Keyless local-style preset as ACTIVE chat provider with the model
        // deliberately unchosen — exactly the state the exit prompt exists for.
        app.launchEnvironment["PROVIDER_SETTINGS_JSON"] = """
        {"presetId":"ollama","baseURL":"http://127.0.0.1:8555/v1","model":""}
        """
        app.launchArguments += ["-onboarding.completed.v1", "1"]
        // Neutralize persisted provider PROFILES for this launch:
        // SettingsStore.init hydrates an empty settings.model from the ollama
        // profile, so a model committed by any earlier run on this simulator
        // would silently defuse the exit prompt under test. The argument-domain
        // string shadows the stored Data — data(forKey:) then reads nil.
        app.launchArguments += ["-provider-profiles-v1", "test-reset"]
        // Pin the app to German so localized labels are deterministic
        // regardless of the simulator's language.
        app.launchArguments += ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
    }

    /// Mehr → KI-Anbieter → Schnellstart → Ollama (the active chat provider).
    private func openOllamaProvider() {
        // firstMatch: the tab bar can momentarily expose duplicate tab buttons
        // (floating + inline variants) — tapping the ambiguous query errors.
        let mehr = app.tabBars.buttons["Mehr"].firstMatch
        XCTAssertTrue(mehr.waitForExistence(timeout: 10), "tab bar should offer Mehr")
        mehr.tap()
        let connections = app.buttons["open-connections"]
        XCTAssertTrue(connections.waitForExistence(timeout: 10), "Mehr should offer KI-Anbieter")
        connections.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ollama'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Schnellstart should list Ollama")
        row.tap()
    }

    /// Probe succeeds against the stub — and commits NOTHING: the exit-prompt
    /// back button still intercepts, and leaving still raises the question.
    func testProbeSucceedsAndCommitsNoModel() {
        app.launch()
        openOllamaProvider()

        let testButton = app.buttons["test-connection"]
        XCTAssertTrue(testButton.waitForExistence(timeout: 10), "Diagnose section should offer the probe")
        testButton.tap()

        let success = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Verbunden'")).firstMatch
        XCTAssertTrue(success.waitForExistence(timeout: 20), "probe against the stub should succeed")

        // A green probe must NOT have committed the auto-picked model.
        let back = app.buttons["provider-back"]
        XCTAssertTrue(back.exists, "no model committed → exit prompt must still intercept")
        back.tap()
        XCTAssertTrue(app.staticTexts["Kein Modell gewählt"].waitForExistence(timeout: 5),
                      "leaving without a model should ask first")
        app.buttons["Ohne Modell verlassen"].tap()
        XCTAssertTrue(app.navigationBars["Anbieter"].waitForExistence(timeout: 10),
                      "leaving without a model stays allowed")
    }

    /// "Modelle laden" also only SUGGESTS; the explicit choice (here: the
    /// one-tap suggestion in the exit dialog) is what commits — after which
    /// the system back button is restored.
    func testExplicitPickCommitsAndReleasesTheExitPrompt() {
        app.launch()
        openOllamaProvider()

        let fetch = app.buttons["fetch-models"]
        XCTAssertTrue(fetch.waitForExistence(timeout: 10))
        fetch.tap()
        // List arrived: the button relabels with the count. Still uncommitted.
        let refreshed = app.buttons.matching(
            NSPredicate(format: "identifier == 'fetch-models' AND label CONTAINS 'aktualisieren'")
        ).firstMatch
        XCTAssertTrue(refreshed.waitForExistence(timeout: 20), "stub model list should load")
        let back = app.buttons["provider-back"]
        XCTAssertTrue(back.exists, "a fetched suggestion alone must not commit a model")

        // Exit dialog offers the highlighted suggestion; taking it commits.
        back.tap()
        let useSuggestion = app.buttons
            .matching(NSPredicate(format: "label CONTAINS 'stub-' AND label ENDSWITH 'verwenden'"))
            .firstMatch
        XCTAssertTrue(useSuggestion.waitForExistence(timeout: 5),
                      "dialog should offer the suggested model")
        useSuggestion.tap()
        XCTAssertTrue(app.navigationBars["Anbieter"].waitForExistence(timeout: 10))

        // Re-enter: with a committed model the system back button is back.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ollama'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["test-connection"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["provider-back"].exists,
                       "committed model → no exit interception any more")
    }
}
