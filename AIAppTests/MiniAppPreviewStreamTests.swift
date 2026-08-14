import XCTest
@testable import AIApp

/// The rule that lets an open mini-app preview build itself while the model is
/// still writing the document.
///
/// The whole point is that a streaming preview is a CHEAPER way to show the
/// same thing, never a different thing: it may only ever swap the body of a
/// page that is already loaded and already hardened, and the finished app must
/// still arrive through the ordinary `loadHTMLString`. So the tests here lean
/// two ways deliberately — towards reloading whenever anything about the
/// document's identity moves, and towards guaranteeing the final load happens
/// even when the DOM already shows exactly those bytes.
///
/// Everything below is pure: no WebKit, no `UserDefaults` writes, no clock.
/// `@MainActor` only because `MiniAppRunnerView` inherits the isolation of
/// `UIViewRepresentable` — the policy itself has none.
@MainActor
final class MiniAppPreviewStreamTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func doc(_ body: String, capability: String? = nil, head: String = "") -> String {
        let marker = capability.map { "<!-- capability: \($0) -->\n" } ?? ""
        return """
        <!doctype html>
        \(marker)<html><head>\(head)</head><body>\(body)</body></html>
        """
    }

    private func decide(
        next: String,
        isStreaming: Bool = true,
        capability: MiniAppCapability = .offline,
        capabilityChanged: Bool = false,
        isUserInteracting: Bool = false,
        loaded: String? = nil,
        patched: String? = nil,
        lastPatchAt: Date? = nil,
        at offset: TimeInterval = 0,
        minimumInterval: TimeInterval = MiniAppPreviewStream.minimumPatchInterval
    ) -> MiniAppPreviewStream.Action {
        MiniAppPreviewStream.action(
            for: next,
            isStreaming: isStreaming,
            capability: capability,
            capabilityChanged: capabilityChanged,
            isUserInteracting: isUserInteracting,
            state: MiniAppPreviewStream.State(
                loadedHTML: loaded,
                patchedHTML: patched,
                lastPatchAt: lastPatchAt
            ),
            now: epoch.addingTimeInterval(offset),
            minimumInterval: minimumInterval
        )
    }

    // MARK: - What is on screen

    func testAPatchIsWhatTheViewerSeesUntilTheNextRealLoad() {
        var state = MiniAppPreviewStream.State(loadedHTML: "a", patchedHTML: nil, lastPatchAt: nil)
        XCTAssertEqual(state.visibleHTML, "a")
        state.patchedHTML = "ab"
        XCTAssertEqual(state.visibleHTML, "ab")
    }

    // MARK: - Reload, always

    func testTheFirstDocumentIsLoadedRatherThanPatched() {
        XCTAssertEqual(decide(next: doc("<p>hi</p>"), loaded: nil), .reload)
    }

    func testAChangeOutsideAStreamIsAnOrdinaryReload() {
        XCTAssertEqual(
            decide(next: doc("<p>b</p>"), isStreaming: false, loaded: doc("<p>a</p>")),
            .reload
        )
    }

    func testATierChangeAlwaysReloadsBecauseTheCSPMustBeRewritten() {
        // Same bytes, but the document has to be hardened again — a body patch
        // cannot change the policy the page is already running under.
        let html = doc("<p>a</p>")
        XCTAssertEqual(
            decide(next: html, capability: .network, capabilityChanged: true, loaded: html, patched: html),
            .reload
        )
    }

    func testADeclaredTierAppearingMidStreamReloads() {
        // The `<!-- capability: … -->` comment picks the CSP, so the moment it
        // shows up the patched document is no longer the one that was hardened.
        XCTAssertEqual(
            decide(
                next: doc("<p>a</p>", capability: "network"),
                loaded: doc("<p>a</p>")
            ),
            .reload
        )
    }

    func testABrowserTargetAppearingMidStreamReloads() {
        // `<!-- open: … -->` makes the runner load a remote URL instead of the
        // generated shell — a different document entirely.
        let current = doc("<p>a</p>", capability: "browser")
        let next = current.replacingOccurrences(
            of: "<!doctype html>",
            with: "<!doctype html>\n<!-- open: https://example.com -->"
        )
        XCTAssertEqual(decide(next: next, capability: .offline, loaded: current), .reload)
    }

    func testABrowserTierDocumentIsNeverPatched() {
        // Its document is a third-party page, not a body this app owns.
        XCTAssertEqual(
            decide(next: doc("<p>b</p>"), capability: .browser, loaded: doc("<p>a</p>")),
            .reload
        )
    }

    // MARK: - The final artifact

    func testTheFinishedDocumentIsLoadedEvenWhenTheDOMAlreadyShowsThoseBytes() {
        // The single most important case: a patch never runs <script>, so a
        // preview that ends on patched content is NOT the app. Streaming is an
        // affordance; the shipped document always goes through loadHTMLString.
        let html = doc("<p>done</p>")
        XCTAssertEqual(
            decide(next: html, isStreaming: false, loaded: doc("<p>d</p>"), patched: html),
            .reload
        )
    }

    func testAFinishedDocumentThatWasNeverPatchedIsNotReloadedAgain() {
        let html = doc("<p>done</p>")
        XCTAssertEqual(decide(next: html, isStreaming: false, loaded: html, patched: nil), .ignore)
    }

    func testUnchangedContentDuringTheStreamDoesNothing() {
        let html = doc("<p>a</p>")
        XCTAssertEqual(decide(next: html, loaded: doc("<p>x</p>"), patched: html), .ignore)
    }

    // MARK: - Patching

    func testGrowingContentDuringTheStreamPatches() {
        XCTAssertEqual(
            decide(next: doc("<p>a</p><p>b</p>"), loaded: doc("<p>a</p>")),
            .patch
        )
    }

    func testTheFirstPatchAfterALoadIsNotThrottled() {
        XCTAssertEqual(
            decide(next: doc("<p>ab</p>"), loaded: doc("<p>a</p>"), lastPatchAt: nil),
            .patch
        )
    }

    func testASecondPatchInsideTheIntervalIsDropped() {
        XCTAssertEqual(
            decide(
                next: doc("<p>abc</p>"),
                loaded: doc("<p>a</p>"),
                patched: doc("<p>ab</p>"),
                lastPatchAt: epoch,
                at: MiniAppPreviewStream.minimumPatchInterval / 2
            ),
            .ignore
        )
    }

    func testContentDroppedByTheThrottleIsTakenByTheNextChunk() {
        // Dropping a chunk is free: every patch carries the WHOLE document, so
        // the next one contains everything the skipped one did.
        XCTAssertEqual(
            decide(
                next: doc("<p>abc</p>"),
                loaded: doc("<p>a</p>"),
                patched: doc("<p>ab</p>"),
                lastPatchAt: epoch,
                at: MiniAppPreviewStream.minimumPatchInterval + 0.01
            ),
            .patch
        )
    }

    func testNothingIsSwappedUnderTheUsersFinger() {
        XCTAssertEqual(
            decide(next: doc("<p>ab</p>"), isUserInteracting: true, loaded: doc("<p>a</p>")),
            .ignore
        )
    }

    func testReduceMotionKeepsBuildingJustFarLessOften() {
        XCTAssertGreaterThan(
            MiniAppPreviewStream.reducedMotionPatchInterval,
            MiniAppPreviewStream.minimumPatchInterval
        )
        let args = (loaded: doc("<p>a</p>"), next: doc("<p>ab</p>"))
        XCTAssertEqual(
            decide(next: args.next, loaded: args.loaded, lastPatchAt: epoch,
                   at: 0.5, minimumInterval: MiniAppPreviewStream.reducedMotionPatchInterval),
            .ignore
        )
        XCTAssertEqual(
            decide(next: args.next, loaded: args.loaded, lastPatchAt: epoch,
                   at: MiniAppPreviewStream.reducedMotionPatchInterval + 0.1,
                   minimumInterval: MiniAppPreviewStream.reducedMotionPatchInterval),
            .patch
        )
    }

    // MARK: - What counts as structural

    func testTheModelsOwnHeadIsNotStructural() {
        // `Sandbox.harden` owns the real <head>; the model's markup — head
        // included — is placed inside the body of a document whose CSP is
        // already in force. Reloading when that head grows would rebuild the
        // identical DOM and throw the page away for nothing, which is exactly
        // the flicker this feature exists to remove. The head grows on almost
        // every chunk early in a stream, so this is the common case.
        let early = doc("", head: "<style>body{color:red}</style>")
        let later = doc("<p>a</p>", head: "<style>body{color:red}</style><title>Timer</title>")
        XCTAssertEqual(
            MiniAppPreviewStream.structuralSignature(of: early),
            MiniAppPreviewStream.structuralSignature(of: later)
        )
        XCTAssertEqual(decide(next: later, loaded: early), .patch)
    }

    func testTheSignatureIsTheTierAndTheOpenTarget() {
        XCTAssertNotEqual(
            MiniAppPreviewStream.structuralSignature(of: doc("x")),
            MiniAppPreviewStream.structuralSignature(of: doc("x", capability: "network"))
        )
        XCTAssertNotEqual(
            MiniAppPreviewStream.structuralSignature(of: doc("x", capability: "browser")),
            MiniAppPreviewStream.structuralSignature(
                of: "<!-- open: https://example.com -->" + doc("x", capability: "browser")
            )
        )
    }

    // MARK: - The injected script

    func testAJavaScriptLiteralCannotBreakOutOfItsQuotes() {
        let hostile = "</div>\" ; alert(1); var x = \"\n\\ back"
        guard let literal = MiniAppPreviewStream.jsStringLiteral(hostile) else {
            return XCTFail("no literal")
        }
        XCTAssertTrue(literal.hasPrefix("\""))
        XCTAssertTrue(literal.hasSuffix("\""))
        XCTAssertFalse(literal.contains("\n"), "a raw newline would end the statement")
        XCTAssertTrue(literal.contains("\\\""), "quotes must be escaped, not passed through")
    }

    func testLineSeparatorsAreEscapedForOlderJavaScriptSourceRules() {
        guard let literal = MiniAppPreviewStream.jsStringLiteral("a\u{2028}b\u{2029}c") else {
            return XCTFail("no literal")
        }
        XCTAssertFalse(literal.contains("\u{2028}"))
        XCTAssertFalse(literal.contains("\u{2029}"))
        XCTAssertTrue(literal.contains("u2028"))
        XCTAssertTrue(literal.contains("u2029"))
    }

    func testThePatchScriptRemovesScriptsRestoresScrollAndParsesDetached() {
        guard let script = MiniAppPreviewStream.patchScript(hardenedHTML: doc("<p>a</p>")) else {
            return XCTFail("no script")
        }
        // Detached parse: a half-written document is never the thing on screen.
        XCTAssertTrue(script.contains("document.createElement('div')"))
        // Scripts are dropped rather than relied on not to execute — a
        // truncated one could throw, and its timers would outlive the patch.
        XCTAssertTrue(script.contains("querySelectorAll('script')"))
        XCTAssertTrue(script.contains("remove()"))
        // Replacing the body resets the offset; the reader keeps their place.
        XCTAssertTrue(script.contains("window.scrollY"))
        XCTAssertTrue(script.contains("window.scrollTo"))
        // No navigation: the page, its origin and its CSP stay exactly as they
        // were loaded.
        XCTAssertFalse(script.contains("location"))
    }

    // MARK: - Hardening

    func testTheStreamedDocumentIsHardenedExactlyLikeTheLoadedOne() {
        // One hardening call site serves both paths, so a preview can never see
        // a looser policy than the app it is previewing. A random preview id
        // has no consent record, so no host can be in play either.
        let appId = "preview-\(UUID().uuidString)"
        let html = doc("<p>a</p>")
        let hardened = MiniAppRunnerView.hardenedDocument(html: html, capability: .offline, appId: appId)
        XCTAssertEqual(hardened, Sandbox.harden(html, capability: .offline))
        XCTAssertTrue(hardened.contains("default-src 'none'"))
        XCTAssertTrue(hardened.contains("<meta http-equiv=\"Content-Security-Policy\""))
    }

    func testAStreamedNetworkDocumentGetsNoHostItWasNotGranted() {
        let appId = "preview-\(UUID().uuidString)"
        let html = doc("<p>a</p>", capability: "network")
        let hardened = MiniAppRunnerView.hardenedDocument(html: html, capability: .network, appId: appId)
        XCTAssertTrue(hardened.contains("connect-src 'none'"))
    }
}
