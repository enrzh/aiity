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
        let bar = app.descendants(matching: .any)["chat-composer-bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "composer bar container should exist")

        // Resting position: within the bottom chrome band (composer padding +
        // tab bar + home indicator) — device-independent: bottom 20% of window.
        let restingMaxY = input.frame.maxY
        XCTAssertLessThan(
            window.frame.maxY - restingMaxY, window.frame.height * 0.2,
            "composer should rest near the bottom, not mid-screen"
        )

        // What "flush" has to mean, measured instead of guessed: at rest the
        // bar's bottom edge sits this far above the bottom chrome (the tab bar
        // top is the composer container's bottom edge). The gap is the
        // composer's own inner padding — landing ON the keyboard means
        // reproducing exactly this gap against the keyboard's top edge, so the
        // check stays a relative one with no pixel constants.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "tab bar should be the bottom chrome")
        let restingGap = tabBar.frame.minY - bar.frame.maxY
        XCTAssertGreaterThanOrEqual(restingGap, 0, "composer must rest ON the tab bar, not under it")

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
            // The assertion whose absence let build 7 ship: rising is not
            // enough — the bar must land ON the keyboard. The regression was a
            // lift computed from keyboard HEIGHT minus an assumed bottom
            // inset, which overshot and parked the bar a chrome-height above
            // the keyboard while every rise/return check still passed.
            let flush = waitUntil(timeout: 6) {
                guard let top = self.keyboardTopEdge() else { return false }
                return abs((top - bar.frame.maxY) - restingGap) <= 3
            }
            XCTAssertTrue(
                flush,
                "composer bottom should sit flush on the keyboard top "
                    + "(bar.maxY=\(bar.frame.maxY) keyboardTop=\(keyboardTopEdge().map(String.init(describing:)) ?? "nil") "
                    + "gap=\((keyboardTopEdge() ?? 0) - bar.frame.maxY)pt, "
                    + "expected the resting gap \(restingGap)pt)"
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

    /// The keyboard's REAL top edge, in window coordinates.
    ///
    /// `app.keyboards.firstMatch.frame` is NOT it: that element covers the KEY
    /// PLANE only. Above the keys sits the input-assistant (QuickType) strip —
    /// 44 pt on iOS 26 — which is part of the keyboard, is included in the
    /// frame UIKit publishes in its keyboard notifications, and is therefore
    /// part of what the composer has to sit on. Measuring against the key
    /// plane made a correctly positioned composer read as 44 pt short (a
    /// phantom "gap" on the 6.9" class, where that strip is vended as a
    /// separate element). The host view wrapping the whole keyboard is exposed
    /// as `inputView`; take the TOPMOST on-screen candidate so a runtime that
    /// vends only some of these still yields the true edge.
    private func keyboardTopEdge() -> CGFloat? {
        let window = app.windows.firstMatch.frame
        // A keyboard's top edge is always in the lower half of a portrait
        // window; anything higher is a stale or offscreen host view.
        func plausible(_ frame: CGRect) -> Bool {
            frame.height > 1 && frame.minY > window.midY && frame.minY < window.maxY - 1
        }
        var candidates: [CGFloat] = []
        for identifier in ["inputView", "SystemInputAssistantView"] {
            let matches = app.descendants(matching: .any).matching(identifier: identifier)
            for element in matches.allElementsBoundByIndex where plausible(element.frame) {
                candidates.append(element.frame.minY)
            }
        }
        let keys = app.keyboards.firstMatch
        if keys.exists, plausible(keys.frame) { candidates.append(keys.frame.minY) }
        return candidates.min()
    }

    /// The Chat tab opens the conversation LIST; create and enter a chat.
    private func openFreshChat() {
        let compose = app.buttons["new-chat"]
        XCTAssertTrue(compose.waitForExistence(timeout: 20), "compose button should exist on the chat list")
        let solo = app.buttons["new-solo-chat"]
        XCTAssertTrue(tap(compose, until: solo), "new-chat sheet should offer a solo chat")
        let input = app.descendants(matching: .any)["chat-input"].firstMatch
        XCTAssertTrue(tap(solo, until: input), "solo chat should open the composer")
    }

    /// Tap `control` until `target` appears — bounded, never blind.
    ///
    // `tap(_:until:)` — the bounded tap-and-verify this suite also carried a
    // copy of — now lives once in UITestSupport.swift.

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
