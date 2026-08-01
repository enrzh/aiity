import XCTest

/// Drives the crash-report path end to end through the real UI.
///
/// Worth having as a UI test rather than only unit tests: the first build of
/// this feature had a correct recorder and an invisible banner, because `.task`
/// on a `Group` never fires while the Group is empty. No unit test would have
/// caught that — only rendering it does.
final class DiagnosticsUITests: XCTestCase {

    /// A run that ended in a caught SIGSEGV, as the previous launch would have
    /// left behind on disk.
    private static let crashedRun = """
    {
      "id": "5D2E1A77-1C4B-4E90-9A1F-0B2C3D4E5F60",
      "startedAt": 770000000,
      "appVersion": "0.6.0",
      "build": "44",
      "systemVersion": "26.0",
      "deviceModel": "iPhone17,1",
      "lastActiveAt": 770000500,
      "wasInBackground": false,
      "memoryWarnings": 0,
      "footprintMB": 412,
      "availableMemoryMB": 1200,
      "provider": "anthropic",
      "model": "claude-opus-4-5",
      "breadcrumbs": [
        {"at": 770000499, "category": "gruppe", "message": "Runde 2 · 3 Teilnehmer"}
      ],
      "fatal": {
        "kind": "signal",
        "at": 770000500,
        "name": "SIGSEGV",
        "reason": "Ungültiger Speicherzugriff — Zugriff auf bereits freigegebenen Speicher.",
        "frames": ["0x1044e2a10"]
      }
    }
    """

    /// The same run, but shut down in an orderly way.
    private static let cleanRun = """
    {
      "id": "9F3C2B18-4D5E-4A6F-8B7C-1D2E3F405162",
      "startedAt": 770000000,
      "endedCleanlyAt": 770000400,
      "lastActiveAt": 770000400,
      "appVersion": "0.6.0",
      "build": "44",
      "systemVersion": "26.0",
      "deviceModel": "iPhone17,1",
      "breadcrumbs": []
    }
    """

    /// SwiftUI decides for itself which XCUIElement type a view becomes, and it
    /// is not stable across containers — the same identifier surfaces as
    /// `.other` in a VStack and `.button` or `.cell` inside a Form. Match on
    /// the identifier alone rather than guessing the type.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// `app.staticTexts["…"]` matches the IDENTIFIER, not the visible text —
    /// which for SwiftUI views that never set one matches nothing at all. Every
    /// assertion about what the screen actually says has to go through a label
    /// predicate.
    private func text(_ app: XCUIApplication, containing needle: String) -> XCUIElement {
        app.staticTexts.element(matching: NSPredicate(format: "label CONTAINS %@", needle))
    }

    private func hasText(_ app: XCUIApplication, _ needle: String, timeout: TimeInterval = 5) -> Bool {
        text(app, containing: needle).waitForExistence(timeout: timeout)
    }

    private func launch(seed: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboarding.completed.v1", "1"]
        if let seed { app.launchEnvironment["AIITY_DIAGNOSTICS_SEED"] = seed }
        app.launch()
        return app
    }

    /// The whole point of the feature: after a bad run the user is told, on the
    /// first screen, without going to iOS Settings and without being asked to
    /// go looking for it.
    func testTheCrashNoticeAppearsWithTheVerdict() {
        let app = launch(seed: Self.crashedRun)

        let notice = element(app, "crash-notice")
        XCTAssertTrue(
            notice.waitForExistence(timeout: 20),
            "a crashed previous run must announce itself on the first screen"
        )
        XCTAssertTrue(notice.label.contains("SIGSEGV"), notice.label)
    }

    /// A clean run must not raise an alarm — a banner that always shows would
    /// train the user to dismiss it.
    ///
    /// Seeded explicitly rather than left empty: the app container survives
    /// between launches, so `nil` would inherit whatever the previous test
    /// crashed with and this would pass or fail on test ordering.
    func testNoNoticeWhenNothingWentWrong() {
        let app = launch(seed: Self.cleanRun)
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 20))
        XCTAssertFalse(element(app, "crash-notice").exists)
    }

    // NOTE: opening the report — tapping "Ansehen", and the Mehr → Diagnose
    // row — is deliberately NOT asserted here. SwiftUI does not surface
    // accessibility identifiers declared on rows inside List/Form (they land
    // on the enclosing cell), the element subscript matches identifiers rather
    // than visible labels, and `app.tabBars` does not resolve with this app's
    // hidden tab-bar background. Several attempts at each produced tests that
    // failed while the screen was demonstrably correct, which is worse than no
    // test. Both screens are covered by DiagnosticsReport unit tests for their
    // content and were verified by screenshot on the simulator.
}
