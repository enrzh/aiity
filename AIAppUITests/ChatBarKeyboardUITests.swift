import XCTest

/// Regression gate for "composer floats mid-screen with no keyboard visible":
/// the bar's position used to ride SwiftUI's implicit keyboard safe-area
/// inset, which sheet-dismissal/tab-switch races can leave stale. ChatView now
/// opts out of that inset and lifts the bar itself (KeyboardObserver), and
/// resigns composer focus before any sheet presents. Pre-fix, this test
/// failed at the skills-sheet phase (bar stuck at former-keyboard height
/// after the sheet round-trip); it must stay green.
///
/// Assertions are relative-frame only — the composer's resting maxY is
/// captured once and every phase must return to it. No pixel constants, and
/// nothing REQUIRES a software keyboard (a connected hardware keyboard in the
/// simulator just degrades the keyboard phases to no-ops instead of failing).
final class ChatBarKeyboardUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip the first-run onboarding wizard (writes the completed flag).
        app.launchArguments += ["-onboarding.completed.v1", "1"]
    }

    func testComposerRestsAtBottomThroughKeyboardAndSheetRoundTrips() {
        app.launch()
        openFreshChat()

        let input = app.descendants(matching: .any)["chat-input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15), "chat input should exist")
        let window = app.windows.firstMatch

        // Resting position: within the bottom chrome band (composer padding +
        // tab bar + home indicator) — device-independent: bottom 20% of window.
        let restingMaxY = input.frame.maxY
        XCTAssertLessThan(
            window.frame.maxY - restingMaxY, window.frame.height * 0.2,
            "composer should rest near the bottom, not mid-screen"
        )

        // --- Phase 1: keyboard round-trip on the composer itself.
        input.tap()
        // Existence alone is not enough for the hardware-keyboard no-op
        // degrade (see header): some runtimes vend a phantom Keyboard element
        // (sometimes even with keys) while nothing is presented on screen —
        // composer focused, tab bar fully visible and hittable. Only a
        // keyboard that actually OCCUPIES WINDOW SPACE can lift the composer;
        // anything else is the hardware-keyboard case this test deliberately
        // degrades on. The frame check matches how the phantom behaves in
        // AX hit-testing: it covers nothing.
        let keyboard = app.keyboards.firstMatch
        _ = keyboard.waitForExistence(timeout: 3)
        let keyboardOnScreen = waitUntil {
            keyboard.exists && keyboard.frame.height > 1
                && keyboard.frame.minY < window.frame.maxY - 1
        }
        if keyboardOnScreen {
            XCTAssertTrue(
                waitUntil { input.frame.maxY < restingMaxY - 60 },
                "composer should rise with the keyboard"
            )
            // .scrollDismissesKeyboard(.immediately) — a deliberate drag on the
            // transcript region drops it. (Element-based swipeDown proved
            // unreliable: firstMatch can resolve inside the keyboard itself.)
            dragTranscriptDown()
            XCTAssertTrue(
                waitUntil { self.app.keyboards.count == 0 },
                "scroll drag should dismiss the keyboard (scrollDismissesKeyboard)"
            )
        }
        assertComposerAtRest(input, restingMaxY: restingMaxY, "after keyboard round-trip")

        // --- Phase 2: sheet presented while the composer keyboard is up,
        // then swipe-dismissed (report mechanism 1, native-field variant).
        input.tap()
        app.buttons["chat-skills"].tap()
        XCTAssertTrue(app.navigationBars["Skills"].waitForExistence(timeout: 10), "skills sheet should open")
        dismissSheet()
        XCTAssertTrue(
            waitUntil { !self.app.navigationBars["Skills"].exists },
            "skills sheet should swipe-dismiss"
        )
        assertComposerAtRest(input, restingMaxY: restingMaxY, "after skills sheet round-trip")

        // --- Phase 3: connections sheet with ITS OWN keyboard up, then
        // swipe-dismissed with the keyboard still visible (report flow e).
        app.buttons["chat-provider"].tap()
        XCTAssertTrue(app.navigationBars["Anbieter"].waitForExistence(timeout: 10), "connections sheet should open")
        let sheetField = app.textFields.firstMatch
        if sheetField.waitForExistence(timeout: 5), sheetField.isHittable {
            sheetField.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        }
        dismissSheet()
        XCTAssertTrue(
            waitUntil { !self.app.navigationBars["Anbieter"].exists },
            "connections sheet should swipe-dismiss"
        )
        assertComposerAtRest(input, restingMaxY: restingMaxY, "after connections sheet dismissed with its keyboard up")
    }

    // MARK: - Helpers

    /// The Chat tab opens the conversation LIST; create and enter a chat.
    private func openFreshChat() {
        let compose = app.buttons["new-chat"]
        XCTAssertTrue(compose.waitForExistence(timeout: 15), "compose button should exist on the chat list")
        compose.tap()
        let solo = app.buttons["new-solo-chat"]
        XCTAssertTrue(solo.waitForExistence(timeout: 10), "new-chat sheet should offer a solo chat")
        solo.tap()
    }

    /// A slow, deliberate downward drag across the transcript (upper third of
    /// the window, well clear of the keyboard) — registers as a scroll so
    /// `.scrollDismissesKeyboard(.immediately)` fires.
    private func dragTranscriptDown() {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: end)
    }

    /// Drag down from the sheet's grabber region to swipe-dismiss it.
    private func dismissSheet() {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// The bug is a bar STUCK a full keyboard height above its resting spot,
    /// so the tolerance is loose (8 pt) but the poll is patient: dismissal and
    /// keyboard animations need a beat to settle.
    private func assertComposerAtRest(_ input: XCUIElement, restingMaxY: CGFloat, _ context: String) {
        let settled = waitUntil(timeout: 6) { abs(input.frame.maxY - restingMaxY) < 8 }
        XCTAssertTrue(
            settled,
            "composer stuck at maxY=\(input.frame.maxY) vs resting \(restingMaxY) \(context) (keyboards on screen: \(app.keyboards.count))"
        )
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
