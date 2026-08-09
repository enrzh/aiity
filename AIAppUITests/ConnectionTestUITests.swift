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
        XCTAssertTrue(mehr.waitForExistence(timeout: 15), "tab bar should offer Mehr")
        let connections = app.buttons["open-connections"]
        XCTAssertTrue(tap(mehr, until: connections), "Mehr should offer KI-Anbieter")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ollama'")).firstMatch
        XCTAssertTrue(tap(connections, until: row), "Schnellstart should list Ollama")
        // The form's navigation title is the preset label ("Ollama (eigener
        // Rechner)") — a target that is on screen whatever the list scroll
        // position or the commit state is. Matched by prefix so a relabelled
        // preset does not turn into a mystery timeout.
        XCTAssertTrue(tap(row, until: providerForm), "Ollama row should open the provider form")
    }

    /// The provider form, identified by its navigation title (the preset label).
    private var providerForm: XCUIElement {
        app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH 'Ollama'")).firstMatch
    }

    /// Tap `control` until `target` shows up — bounded, never blind.
    ///
    /// `XCUIElement.tap()` does NOT wait for hittability: it computes a hit
    /// point from the current snapshot and, when the element is covered, gets
    /// {-1, -1} and drops the event silently — the test then waits out its
    /// whole timeout on a screen that never changed. Two things cover these
    /// controls here: the cold-start splash (LaunchSplashView is up for ~1 s
    /// over a tab bar that already EXISTS in the tree), and any other app the
    /// simulator brings to the front mid-run. So: wait for hittability, tap,
    /// verify the screen actually moved on, and otherwise tap again.
    @discardableResult
    private func tap(_ control: XCUIElement, until target: XCUIElement, attempts: Int = 4) -> Bool {
        for attempt in 0..<attempts {
            if target.exists { return true }
            let hittable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isHittable == true"), object: control)
            guard XCTWaiter.wait(for: [hittable], timeout: 10) == .completed else { continue }
            control.tap()
            if target.waitForExistence(timeout: attempt == 0 ? 6 : 4) { return true }
        }
        return target.exists
    }

    /// The provider form is a lazy List that is taller than smaller screens
    /// (e.g. iPhone 17 Pro): rows below the fold — the Diagnose section in
    /// particular — are never materialized, so a plain waitForExistence can
    /// never see them. Swipe up (bounded) until the element is materialized
    /// and actually hittable; on tall screens the first wait returns at once.
    @discardableResult
    private func revealByScrolling(_ element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        if element.waitForExistence(timeout: 5), element.isHittable { return true }
        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1), element.isHittable { return true }
        }
        return element.exists
    }

    /// Confirmation dialogs animate in; a tap synthesized while the sheet is
    /// still settling snapshots a stale hit point and can land beside the
    /// button, leaving the dialog open. Wait for hittability first, and if
    /// the button is still on screen shortly after the tap, tap once more.
    private func tapDialogButton(_ button: XCUIElement) {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: button)
        _ = XCTWaiter.wait(for: [hittable], timeout: 5)
        button.tap()
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: button)
        if XCTWaiter.wait(for: [gone], timeout: 3) != .completed, button.exists {
            button.tap() // first tap missed the still-animating dialog
        }
    }

    /// Probe succeeds against the stub — and commits NOTHING: the exit-prompt
    /// back button still intercepts, and leaving still raises the question.
    func testProbeSucceedsAndCommitsNoModel() {
        app.launch()
        openOllamaProvider()

        let testButton = app.buttons["test-connection"]
        XCTAssertTrue(revealByScrolling(testButton), "Diagnose section should offer the probe")
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
        tapDialogButton(app.buttons["Ohne Modell verlassen"])
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
        XCTAssertTrue(revealByScrolling(fetch), "provider form should offer Modelle laden")
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
        tapDialogButton(useSuggestion)
        XCTAssertTrue(app.navigationBars["Anbieter"].waitForExistence(timeout: 10))

        // Re-enter: with a committed model the system back button is back.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Ollama'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(tap(row, until: providerForm), "Ollama row should re-open the provider form")
        // Same below-the-fold reality on re-entry: scroll the Diagnose
        // section into existence before asserting on it.
        XCTAssertTrue(revealByScrolling(app.buttons["test-connection"]))
        XCTAssertFalse(app.buttons["provider-back"].exists,
                       "committed model → no exit interception any more")
    }
}
