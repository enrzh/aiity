import XCTest

/// Helpers every UI suite needs, in ONE place.
///
/// They all exist for the same reason: `XCUIElement.tap()` does not wait for
/// anything. It computes a hit point from the CURRENT accessibility snapshot
/// and synthesizes a touch there. When the element is present but covered, the
/// hit point comes back as {-1, -1} and the event is dropped silently — the
/// test then waits out its whole timeout on a screen that never changed, and
/// fails one assertion later with a message that describes a symptom rather
/// than the cause.
///
/// Two things cover controls in this app:
///
/// * the launch splash. `RootView` cross-fades `LaunchSplashView` out after a
///   ~0.95 s floor, and during that fade BOTH layers are in the tree — so the
///   tab bar already `exists` (and `waitForExistence` returns at once) while
///   the splash is still on top of it. Every suite that tapped a tab straight
///   after `launch()` was racing that fade.
/// * another app taking the foreground mid-gesture. XCUITest then waits for
///   the intruder to idle, re-activates the target, and fires the touch using
///   the hit point it snapshotted BEFORE all that.
///
/// The answer is the same in both cases and it is not a sleep: wait for
/// hittability, act, verify the screen actually moved on, and otherwise repeat
/// — bounded.
extension XCTestCase {

    // MARK: - Waiting

    /// Poll `condition` until it holds or the deadline passes.
    @discardableResult
    func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// Wait until the element is not merely present but actually tappable.
    @discardableResult
    func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: element)
        return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
    }

    // MARK: - Tapping

    /// Tap `control` until `target` shows up — bounded, never blind.
    ///
    /// Use this for every navigation step whose outcome is observable (a tab
    /// switch, opening a screen). The `target` is what proves the tap landed.
    @discardableResult
    func tap(_ control: XCUIElement, until target: XCUIElement, attempts: Int = 4) -> Bool {
        for attempt in 0..<attempts {
            if target.exists { return true }
            guard waitUntilHittable(control) else { continue }
            control.tap()
            if target.waitForExistence(timeout: attempt == 0 ? 8 : 4) { return true }
        }
        return target.exists
    }

    /// Tap `control` until `condition` holds — for outcomes an element query
    /// alone cannot express (a COUNT going up, a label changing).
    @discardableResult
    func tap(_ control: XCUIElement, untilTrue condition: () -> Bool, attempts: Int = 4) -> Bool {
        for attempt in 0..<attempts {
            if condition() { return true }
            guard waitUntilHittable(control) else { continue }
            control.tap()
            if waitFor(timeout: attempt == 0 ? 8 : 4, condition) { return true }
        }
        return condition()
    }

    /// Tap `control` until `target` is gone — the mirror image of the above,
    /// for actions whose proof is a dismissal (a sheet closing).
    @discardableResult
    func tap(_ control: XCUIElement, untilGone target: XCUIElement, attempts: Int = 4) -> Bool {
        for attempt in 0..<attempts {
            if !target.exists { return true }
            guard waitUntilHittable(control) else { continue }
            control.tap()
            if waitFor(timeout: attempt == 0 ? 8 : 4, { !target.exists }) { return true }
        }
        return !target.exists
    }

    /// Confirmation dialogs and alerts animate in; a tap synthesized while the
    /// dialog is still settling snapshots a stale hit point and can land beside
    /// the button, leaving it open. Wait for hittability first, and if the
    /// button is still on screen shortly after, tap once more.
    func tapDialogButton(_ button: XCUIElement) {
        _ = waitUntilHittable(button, timeout: 5)
        button.tap()
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: button)
        if XCTWaiter.wait(for: [gone], timeout: 3) != .completed, button.exists {
            button.tap() // the first tap missed the still-animating dialog
        }
    }

    // MARK: - Text entry

    /// Whether the element carrying `identifier` currently holds keyboard focus.
    ///
    /// Evaluated as a QUERY predicate (the same `hasKeyboardFocus` attribute
    /// XCUITest itself checks before synthesizing typed text), so it reads the
    /// AX snapshot rather than any private API on `XCUIElement`.
    func isKeyboardFocused(_ identifier: String, in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND hasKeyboardFocus == true", identifier))
            .firstMatch
            .exists
    }

    /// Tap a text input until it really is first responder.
    ///
    /// Best effort on purpose: it returns whether focus was reached and never
    /// asserts. A genuine app-side focus regression therefore still surfaces —
    /// as the `typeText` failure it always was — instead of being hidden
    /// behind a helper that swallows it.
    @discardableResult
    func focusTextInput(_ field: XCUIElement, identifier: String,
                        in app: XCUIApplication, attempts: Int = 3) -> Bool {
        for attempt in 0..<attempts {
            if isKeyboardFocused(identifier, in: app) { return true }
            guard waitUntilHittable(field) else { continue }
            field.tap()
            if waitFor(timeout: attempt == 0 ? 5 : 3, { isKeyboardFocused(identifier, in: app) }) {
                return true
            }
        }
        return isKeyboardFocused(identifier, in: app)
    }

    /// Resolve a text input by identifier, focus it, and type into it.
    @discardableResult
    func typeText(_ text: String, into identifier: String, in app: XCUIApplication,
                  file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let field = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15),
                      "\(identifier) should exist", file: file, line: line)
        focusTextInput(field, identifier: identifier, in: app)
        field.typeText(text)
        return field
    }

    // MARK: - App state

    /// A test's own `terminate()` reads as an unexpected end on the next launch
    /// (a SIGKILL leaves no clean-exit marker), so DiagnosticsRecorder's crash
    /// notice slides in a beat after the screen renders — via `.task` — shifting
    /// everything below it between XCUITest's hit-point snapshot and the
    /// synthesized tap. The banner is real, intended app behaviour; tests just
    /// clear it deterministically before touching anything under it.
    func dismissCrashNoticeIfShown(in app: XCUIApplication) {
        let notice = app.descendants(matching: .any)["crash-notice"].firstMatch
        guard notice.waitForExistence(timeout: 5) else { return }
        let close = app.buttons["Hinweis schließen"].firstMatch
        guard close.exists else { return }
        _ = waitUntilHittable(close, timeout: 5)
        close.tap()
        waitFor(timeout: 5) { !notice.exists }
    }

    /// Wait out the launch splash: the tab bar exists while the splash is still
    /// cross-fading over it, so "exists" is the wrong signal — hittability is.
    /// Returns the resolved tab button so callers can tap it via `tap(_:until:)`.
    @discardableResult
    func waitForTabBar(_ app: XCUIApplication, timeout: TimeInterval = 20) -> Bool {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: timeout) else { return false }
        return waitUntilHittable(tabBar, timeout: timeout)
    }
}
