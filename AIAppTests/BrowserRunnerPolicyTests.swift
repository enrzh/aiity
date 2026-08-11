import XCTest
import WebKit
@testable import AIApp

/// The browser tier's navigation rules. They used to live inline in the
/// Coordinator, where the only way to exercise them was a live site — so the
/// cases that actually broke (custom OAuth callback schemes arriving as `.other`,
/// downloads, blob: links) were never covered by anything.
final class BrowserNavigationPolicyTests: XCTestCase {

    private func decide(_ raw: String,
                        capability: MiniAppCapability = .browser,
                        isMainFrame: Bool = true,
                        isLinkActivated: Bool = false,
                        shouldPerformDownload: Bool = false,
                        isShowingErrorPage: Bool = false,
                        allowedHosts: Set<String> = ["example.com"]) -> BrowserNavigationDecision {
        BrowserNavigationPolicy.decide(
            url: URL(string: raw),
            capability: capability,
            isMainFrame: isMainFrame,
            isLinkActivated: isLinkActivated,
            shouldPerformDownload: shouldPerformDownload,
            isShowingErrorPage: isShowingErrorPage,
            allowedHosts: allowedHosts
        )
    }

    func testPublicWebNavigationIsAllowedOnTheBrowserTier() {
        XCTAssertEqual(decide("https://example.com/deep/page?q=1"), .allow)
        XCTAssertEqual(decide("http://example.com/"), .allow)
        XCTAssertEqual(decide("about:blank"), .allow)
    }

    /// The SSRF gate applies to every hop, not just the first one.
    func testPrivateTargetsStayBlockedOnEveryHop() {
        for raw in ["http://192.168.1.1/admin", "http://127.0.0.1:11434/", "http://100.64.0.1:8090/",
                    "https://nas.local/"] {
            XCTAssertEqual(decide(raw), .cancel, "must refuse \(raw)")
        }
    }

    func testUnGrantedPublicTargetsAndRedirectHostsAreRefused() {
        XCTAssertEqual(decide("https://untrusted.example/", allowedHosts: ["example.com"]), .cancel)
        XCTAssertEqual(decide("https://api.example.com/", allowedHosts: ["example.com"]), .cancel)
        XCTAssertEqual(decide("https://api.example.com/", allowedHosts: ["api.example.com"]), .allow)
    }

    func testRuntimeRejectsIPLiteralsAndExplicitPortsOnNavigationAndExternalLinks() {
        for raw in [
            "https://8.8.8.8/",
            "https://[2001:4860:4860::8888]/",
            "https://example.com:443/",
            "https://example.com:8443/"
        ] {
            XCTAssertEqual(decide(raw, allowedHosts: ["8.8.8.8", "2001:4860:4860::8888", "example.com"]), .cancel,
                           "navigation must refuse \(raw)")
            XCTAssertEqual(decide(raw, capability: .network, isLinkActivated: true,
                                  allowedHosts: ["8.8.8.8", "2001:4860:4860::8888", "example.com"]), .cancel,
                           "external open must refuse \(raw)")
        }
    }

    func testSandboxedExternalLinksStillRequirePublicHostGrants() {
        for capability in [MiniAppCapability.offline, .network] {
            XCTAssertEqual(decide("https://untrusted.example/", capability: capability,
                                  isLinkActivated: true), .cancel)
            XCTAssertEqual(decide("http://127.0.0.1/", capability: capability,
                                  isLinkActivated: true), .cancel)
        }
    }

    func testHostScopedCSPUsesExplicitOrigins() {
        let csp = MiniAppCapability.network.csp(allowedHosts: ["api.example.com"])
        XCTAssertTrue(csp.contains("connect-src https://api.example.com"))
        XCTAssertFalse(csp.contains("http://api.example.com"))
        XCTAssertFalse(csp.contains("connect-src https:;"))
    }

    func testBrowserCSPScopesEveryNetworkDirectiveToValidHTTPSGrants() {
        let csp = MiniAppCapability.browser.csp(allowedHosts: [
            "api.example.com",
            "https://cdn.example.com/assets",
            "example.com:",
            "example.com:443",
            ".untrusted.example.com",
            "8.8.8.8"
        ])

        for directive in ["style-src", "script-src", "img-src", "font-src",
                          "media-src", "connect-src", "frame-src", "child-src"] {
            let policy = csp.split(separator: ";").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(directive) }
            XCTAssertFalse(policy?.split(separator: " ").contains("https:") == true,
                           "\(directive) must not use a broad https source")
        }
        XCTAssertTrue(csp.contains("https://api.example.com"))
        XCTAssertTrue(csp.contains("https://cdn.example.com"))
        XCTAssertFalse(csp.contains("http://"))
        XCTAssertFalse(csp.contains("https://example.com:"))
        XCTAssertFalse(csp.contains("untrusted.example.com"))
        XCTAssertFalse(csp.contains("8.8.8.8"))
    }

    func testMiniAppNavigationRejectsEmptyAndExplicitPorts() {
        for raw in ["https://example.com:/", "https://example.com:443/", "https://example.com:8443/"] {
            XCTAssertEqual(
                decide(raw, allowedHosts: ["example.com"]), .cancel,
                "navigation must refuse explicit port syntax in \(raw)"
            )
        }
    }

    /// The bug: a 302 into an app's own callback scheme arrives as `.other`, so
    /// gating handoff on `.linkActivated` dropped every OAuth return silently.
    func testCustomSchemesAreHandedOffForEveryNavigationType() {
        for raw in ["tel:+4915112345678", "mailto:hi@example.com", "sms:12345",
                    "com.example.app:/oauth2redirect?code=abc", "myapp://callback?code=abc"] {
            guard let url = URL(string: raw) else { return XCTFail("bad fixture \(raw)") }
            XCTAssertEqual(decide(raw, isLinkActivated: false), .openExternally(url),
                           "\(raw) should be offered to the system even without a link tap")
        }
    }

    /// A framed third party must not be able to launch another app.
    func testCustomSchemesInSubframesAreRefused() {
        XCTAssertEqual(decide("myapp://callback", isMainFrame: false), .cancel)
    }

    /// The classic sandbox-escape schemes are never handed anywhere.
    func testEscapeSchemesAreNeverHandedOff() {
        for raw in ["data:text/html,<script>alert(1)</script>", "javascript:alert(1)",
                    "file:///etc/passwd"] {
            XCTAssertEqual(decide(raw), .cancel, "must refuse \(raw)")
        }
    }

    func testDownloadsAreRecognised() {
        XCTAssertEqual(decide("https://example.com/report.pdf", shouldPerformDownload: true), .download)
        XCTAssertEqual(decide("blob:https://example.com/1234", shouldPerformDownload: true), .download)
        XCTAssertEqual(decide("blob:https://example.com/1234"), .allow)
    }

    /// The sandboxed tiers still cannot navigate; a tapped link still needs the
    /// same confirmation the `open.external` bridge action requires.
    func testSandboxedTiersOnlyLeaveViaAConfirmedLinkTap() {
        let url = URL(string: "https://example.com/")!
        for tier in [MiniAppCapability.offline, .network] {
            XCTAssertEqual(decide("https://example.com/", capability: tier, isLinkActivated: true),
                           .openExternally(url))
            XCTAssertEqual(decide("https://example.com/", capability: tier, isLinkActivated: false), .cancel)
            XCTAssertEqual(decide("myapp://callback", capability: tier, isLinkActivated: true), .cancel)
            XCTAssertEqual(decide("https://example.com/", capability: tier,
                                  isMainFrame: false, isLinkActivated: true), .cancel)
        }
    }

    /// The error page's buttons ride on a private scheme. A remote page that
    /// merely contains such a link must not be able to press them.
    func testInternalActionsOnlyWorkOnOurOwnErrorPage() {
        XCTAssertEqual(decide("aiity-runner://retry", isShowingErrorPage: true), .internalAction(.retry))
        XCTAssertEqual(decide("aiity-runner://safari", isShowingErrorPage: true), .internalAction(.safari))
        XCTAssertEqual(decide("aiity-runner://retry", isShowingErrorPage: false), .cancel)
        XCTAssertEqual(decide("aiity-runner://evaluate", isShowingErrorPage: true), .cancel)
    }
}

/// The one-shot cleartext fallback. Narrow on purpose: it exists for the user
/// who typed a bare host that only serves http, and for nothing else.
final class BrowserRetryPolicyTests: XCTestCase {

    private func fallback(_ raw: String,
                          code: Int = NSURLErrorSecureConnectionFailed,
                          assumed: Bool = true,
                          retried: Bool = false) -> URL? {
        BrowserRetryPolicy.httpFallbackURL(for: URL(string: raw)!, errorCode: code,
                                           schemeWasAssumed: assumed, alreadyRetried: retried)
    }

    func testBareHostFallsBackOnceAndKeepsThePath() {
        XCTAssertEqual(fallback("https://alt.example.com/a/b?c=1")?.absoluteString,
                       "http://alt.example.com/a/b?c=1")
        XCTAssertNil(fallback("https://alt.example.com/", retried: true),
                     "the fallback is one-shot; a loop of downgrades is worse than a dead page")
    }

    /// An https the USER asked for is never silently downgraded.
    func testExplicitHTTPSIsNeverDowngraded() {
        XCTAssertNil(fallback("https://alt.example.com/", assumed: false))
    }

    func testOnlyTransportFailuresASchemeChangeCouldFixAreRetried() {
        XCTAssertNotNil(fallback("https://alt.example.com/", code: NSURLErrorCannotConnectToHost))
        XCTAssertNil(fallback("https://alt.example.com/", code: NSURLErrorTimedOut))
        XCTAssertNil(fallback("https://alt.example.com/", code: NSURLErrorNotConnectedToInternet))
    }

    func testOnlyPublicHTTPSURLsQualify() {
        XCTAssertNil(fallback("http://alt.example.com/"), "already cleartext")
        XCTAssertNil(fallback("https://192.168.1.10/"), "a downgrade must not reopen the LAN")
        XCTAssertNil(fallback("https://127.0.0.1:8080/"))
    }

    func testRetryRejectsIPLiteralsAndExplicitPortsWhenGranted() {
        let hosts = ["8.8.8.8", "2001:4860:4860::8888", "example.com"]
        for raw in [
            "https://8.8.8.8/",
            "https://[2001:4860:4860::8888]/",
            "https://example.com:443/",
            "https://example.com:8443/"
        ] {
            XCTAssertNil(
                BrowserRetryPolicy.httpFallbackURL(
                    for: URL(string: raw)!,
                    errorCode: NSURLErrorCannotConnectToHost,
                    schemeWasAssumed: true,
                    alreadyRetried: false,
                    allowedHosts: hosts
                ),
                "retry must refuse \(raw)"
            )
        }
    }
}

/// Recognising a provider that refuses embedded browsers, so the user gets an
/// explanation and a way out instead of a Google error page. aiity deliberately
/// does NOT imitate Safari's user agent to get past this.
final class EmbeddedBrowserRefusalTests: XCTestCase {

    private func refusal(_ raw: String, _ status: Int? = nil) -> Bool {
        EmbeddedBrowserRefusal.isRefusal(url: URL(string: raw)!, statusCode: status)
    }

    func testGoogleDisallowedUserAgentIsRecognised() {
        XCTAssertTrue(refusal("https://accounts.google.com/signin/rejected?error=disallowed_useragent"))
        XCTAssertTrue(refusal("https://accounts.google.com/v3/signin/rejected?dsh=1"))
        XCTAssertTrue(refusal("https://accounts.google.com/o/oauth2/auth?client_id=x", 403))
        XCTAssertTrue(refusal("https://some.host.example/?e=disallowed_useragent"))
    }

    func testOrdinaryPagesAreNotMistakenForARefusal() {
        XCTAssertFalse(refusal("https://accounts.google.com/o/oauth2/auth?client_id=x", 200))
        XCTAssertFalse(refusal("https://accounts.google.com/"))
        XCTAssertFalse(refusal("https://example.com/anything", 403))
        XCTAssertFalse(refusal("https://notaccounts.google.com.evil.example/o/oauth2/auth", 403))
    }
}

/// Popup web views are the one place the capture-deny contract and the bridge
/// gate could silently leak: WebKit hands the child the PARENT's
/// `userContentController`, so the bridge message handler is physically
/// reachable from it.
@MainActor
final class BrowserPopupInvariantsTests: XCTestCase {

    private func makeCoordinator() -> (MiniAppRunnerView.Coordinator, WKWebView) {
        let coordinator = MiniAppRunnerView.Coordinator(appId: "test-app", capability: .browser)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(coordinator, name: "bridge")
        let parent = WKWebView(frame: .zero, configuration: configuration)
        coordinator.webView = parent
        return (coordinator, parent)
    }

    /// Without this, a browser app showing its own trusted home screen could
    /// `window.open` a remote page and have it post to the bridge.
    func testPopupNeverGetsTheBridgeEvenWhileTheParentHasIt() {
        let (coordinator, parent) = makeCoordinator()
        coordinator.beginTrustedLoad()
        XCTAssertTrue(coordinator.acceptsBridgeMessage(from: parent, isMainFrame: true),
                      "the trusted shell itself keeps the bridge")

        let child = coordinator.makeChildWebView(configuration: parent.configuration)
        XCTAssertFalse(coordinator.acceptsBridgeMessage(from: child, isMainFrame: true),
                       "a popup must never reach storage/notify/openExternal")
        XCTAssertFalse(coordinator.acceptsBridgeMessage(from: child, isMainFrame: false))

        // And the leak the identity check exists to close is real: the child
        // genuinely shares the handler-bearing content controller.
        XCTAssertTrue(child.configuration.userContentController === parent.configuration.userContentController)
    }

    /// The capture/motion deny policy lives on the Coordinator's WKUIDelegate
    /// conformance, so the child has to be pointed at the same object.
    func testPopupInheritsTheCaptureDenyDelegate() {
        let (coordinator, parent) = makeCoordinator()
        let child = coordinator.makeChildWebView(configuration: parent.configuration)
        XCTAssertTrue(child.uiDelegate === coordinator, "capture/motion deny must apply to popups")
        XCTAssertTrue(child.navigationDelegate === coordinator, "every hop in a popup must be validated")
    }

    /// The deny handlers themselves are non-constructible to call directly
    /// (`WKSecurityOrigin` has no public initializer), so the contract is
    /// pinned where it can break: the popup pointing at the object that owns it.
    func testCaptureDenyIsImplementedOnTheDelegateThePopupUses() {
        let (coordinator, _) = makeCoordinator()
        XCTAssertTrue(coordinator.responds(to: #selector(WKUIDelegate.webView(_:requestMediaCapturePermissionFor:initiatedByFrame:type:decisionHandler:))))
        XCTAssertTrue(coordinator.responds(to: #selector(WKUIDelegate.webView(_:requestDeviceOrientationAndMotionPermissionFor:initiatedByFrame:decisionHandler:))))
    }

    func testRemoteDocumentLosesTheBridge() {
        let (coordinator, parent) = makeCoordinator()
        coordinator.beginTrustedLoad()
        coordinator.disableBridgeForRemoteDocument()
        XCTAssertFalse(coordinator.acceptsBridgeMessage(from: parent, isMainFrame: true))
    }

    /// A cross-origin <iframe> inside a trusted shell is not the shell.
    func testSubframesNeverGetTheBridge() {
        let (coordinator, parent) = makeCoordinator()
        coordinator.beginTrustedLoad()
        XCTAssertFalse(coordinator.acceptsBridgeMessage(from: parent, isMainFrame: false))
    }
}

/// Apps saved before the `<!-- open: -->` marker existed carried their target
/// only inside the shell body — and the shell can never navigate, so they
/// showed "Öffne host…" forever.
final class LegacyWebAppShellTests: XCTestCase {

    func testLegacyShellLinkIsRecovered() {
        let legacy = """
        <!doctype html><!-- capability: browser -->
        <html><body><p>Öffne x.com…</p>
        <a id="lnk" href="https://x.com/home">Antippen</a>
        <script>location.replace("https://x.com/home");</script>
        </body></html>
        """
        XCTAssertEqual(WebAppBuilder.openTarget(in: legacy)?.absoluteString, "https://x.com/home")
    }

    func testLegacyShellLocationReplaceIsRecovered() {
        let legacy = """
        <!-- capability: browser --><html><body><p>Öffne…</p>
        <script>location.replace("https://alt.example.com/app?a=1&amp;b=2");</script></body></html>
        """
        XCTAssertEqual(WebAppBuilder.openTarget(in: legacy)?.absoluteString,
                       "https://alt.example.com/app?a=1&b=2")
    }

    /// A real mini-app that happens to navigate on a tap must keep rendering
    /// its own UI — the fallback is for the tiny generated shell only.
    func testRichMiniAppIsNotHijacked() {
        let rich = "<!-- capability: browser --><html><body>"
            + String(repeating: "<p>Inhalt</p>", count: 200)
            + "<script>function go(){location.replace(\"https://evil.example/\")}</script></body></html>"
        XCTAssertGreaterThan(rich.count, 1500)
        XCTAssertNil(WebAppBuilder.openTarget(in: rich))
    }

    func testMarkerWinsOverShellBody() {
        let both = """
        <!-- open: https://marker.example/ -->
        <a id="lnk" href="https://shell.example/">x</a>
        """
        XCTAssertEqual(WebAppBuilder.openTarget(in: both)?.absoluteString, "https://marker.example/")
    }

    /// A marker naming a scheme we refuse must not fall through to the shell
    /// link — the shell navigates to that very URL.
    func testRefusedMarkerDoesNotFallThroughToTheShell() {
        let sneaky = """
        <!-- open: file:///etc/passwd -->
        <a id="lnk" href="https://shell.example/">x</a>
        """
        XCTAssertNil(WebAppBuilder.openTarget(in: sneaky))
    }

    func testLegacyShellOnlyRecoversWebSchemes() {
        XCTAssertNil(WebAppBuilder.openTarget(in: "<a id=\"lnk\" href=\"javascript:alert(1)\">x</a>"))
        XCTAssertNil(WebAppBuilder.openTarget(in: "<a id=\"lnk\" href=\"file:///etc/passwd\">x</a>"))
    }

    /// The http fallback is only defensible for a scheme WE guessed.
    func testAssumedSchemeIsRecordedInTheGeneratedApp() {
        XCTAssertTrue(WebAppBuilder.schemeWasAssumed(in: WebAppBuilder.html(urlString: "example.com")))
        XCTAssertFalse(WebAppBuilder.schemeWasAssumed(in: WebAppBuilder.html(urlString: "https://example.com")))
        XCTAssertFalse(WebAppBuilder.schemeWasAssumed(in: WebAppBuilder.html(urlString: "http://example.com")))
        XCTAssertFalse(WebAppBuilder.schemeWasAssumed(in: "<html>egal</html>"))
    }
}
