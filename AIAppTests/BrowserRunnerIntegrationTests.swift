import XCTest
import WebKit
@testable import AIApp

/// Drives a real WKWebView through the runner's Coordinator. These cover the
/// parts a pure decision test cannot reach — whether WebKit actually calls our
/// delegate at all, and whether the page gets control back afterwards. No
/// network: everything runs against an in-memory document.
@MainActor
final class BrowserRunnerIntegrationTests: XCTestCase {

    private func makeRunner(_ capability: MiniAppCapability = .browser)
    -> (MiniAppRunnerView.Coordinator, WKWebView) {
        let coordinator = MiniAppRunnerView.Coordinator(appId: "integration-app", capability: capability)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(coordinator, name: "bridge")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = capability.allowsTopLevelNavigation
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 640),
                                configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.webView = webView
        return (coordinator, webView)
    }

    private func run(_ coordinator: MiniAppRunnerView.Coordinator, _ webView: WKWebView,
                     script: String, capability: MiniAppCapability = .browser) {
        coordinator.beginTrustedLoad()
        webView.loadHTMLString(Sandbox.harden("<script>\(script)</script>", capability: capability),
                               baseURL: nil)
    }

    /// Polls until `expression` is non-nil or the deadline passes.
    private func eventually(_ webView: WKWebView, _ expression: String,
                            timeout: TimeInterval = 8) async -> Any? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = try? await webView.evaluateJavaScript(expression)
            if let value, !(value is NSNull) { return value }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// The bug: with no `runJavaScriptAlertPanel` implementation WebKit answers
    /// nothing at all, so a page that opens with `alert()` stops dead there.
    /// The completion handler must fire even when there is no view controller
    /// to present on, or the WebContent process waits forever.
    func testJavaScriptDialogsAlwaysHandControlBackToThePage() async {
        let (coordinator, webView) = makeRunner()
        run(coordinator, webView, script: """
        alert('hallo');
        window.__confirm = confirm('weiter?');
        window.__prompt = prompt('name?', 'x');
        window.__done = 'reached-the-end';
        """)
        let done = await eventually(webView, "window.__done")
        XCTAssertEqual(done as? String, "reached-the-end",
                       "script execution must resume after every dialog")
        // With no presenter the safe defaults are cancel / nil.
        let confirmed = try? await webView.evaluateJavaScript("window.__confirm === false")
        XCTAssertEqual(confirmed as? Bool, true)
        let prompted = try? await webView.evaluateJavaScript("window.__prompt === null")
        XCTAssertEqual(prompted as? Bool, true)
    }

    /// `window.open` used to return null in every case: the runner refused any
    /// popup without an http(s) URL and loaded the rest into the parent view,
    /// which is exactly what breaks an OAuth window.
    func testWindowOpenGetsARealChildWebView() async {
        let (coordinator, webView) = makeRunner()
        run(coordinator, webView, script: """
        window.__opened = !!window.open('https://example.com/signin', 'oauth');
        """)
        _ = await eventually(webView, "window.__opened")
        XCTAssertEqual(coordinator.popupsCreated, 1, "an OAuth popup must get its own web view")
    }

    /// An about:blank popup the SDK navigates itself — the pattern that was
    /// dropped entirely before.
    func testBlankPopupIsAlsoGivenAWebView() async {
        let (coordinator, webView) = makeRunner()
        run(coordinator, webView, script: "window.__opened = !!window.open('', 'oauth');")
        _ = await eventually(webView, "window.__opened")
        XCTAssertEqual(coordinator.popupsCreated, 1)
    }

    /// The popup path is a second door into the network; the SSRF gate has to
    /// stand in front of it too.
    func testPopupToAPrivateAddressIsRefused() async {
        let (coordinator, webView) = makeRunner()
        run(coordinator, webView, script: """
        window.__opened = window.open('http://192.168.1.10/admin') ? 'yes' : 'no';
        """)
        let opened = await eventually(webView, "window.__opened")
        XCTAssertEqual(opened as? String, "no")
        XCTAssertEqual(coordinator.popupsCreated, 0, "a LAN popup must never get a web view")
    }

    /// The sandboxed tiers keep their old behaviour: no popup web view at all.
    func testSandboxedTiersStillGetNoPopup() async {
        let (coordinator, webView) = makeRunner(.network)
        run(coordinator, webView, script: """
        window.__opened = window.open('https://example.com/') ? 'yes' : 'no';
        """, capability: .network)
        _ = await eventually(webView, "window.__opened", timeout: 4)
        XCTAssertEqual(coordinator.popupsCreated, 0)
    }

    /// The runner's own error page is a null-origin document with
    /// `default-src 'none'` and no bridge — its buttons have to survive that.
    func testErrorPageRendersItsActionsAsLinks() async {
        let html = MiniAppRunnerView.Coordinator.errorHTML(
            url: URL(string: "https://alt.example.com/x"),
            message: "Es besteht keine Verbindung zum Internet.",
            note: "Hinweis",
            actions: [.retry, .safari]
        )
        XCTAssertTrue(html.contains("aiity-runner://retry"))
        XCTAssertTrue(html.contains("aiity-runner://safari"))
        XCTAssertTrue(html.contains("alt.example.com"))

        let (coordinator, webView) = makeRunner()
        coordinator.beginTrustedLoad()
        webView.loadHTMLString(Sandbox.harden(html, capability: .offline), baseURL: nil)
        let links = await eventually(webView, "document.querySelectorAll('a.b').length || null")
        XCTAssertEqual(links as? Int, 2, "both buttons must render in the hardened document")
    }
}
