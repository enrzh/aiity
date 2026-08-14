import XCTest
import WebKit
@testable import AIApp

/// The streaming preview patches a live document's body instead of reloading
/// it. Whether that is actually safe is a question about WebKit's behaviour,
/// not about our policy types — so these run the real patch script against a
/// real web view. No network: everything is an in-memory document.
///
/// Scope is deliberate. Three more behaviours were verified the same way and
/// are NOT kept here, because a `WKWebView` that never joins a window schedules
/// and lays out unreliably enough that asserting them failed roughly one run in
/// three — and a test that cries wolf is worse than no test:
///
///  * a patched fragment's markup and its `<style>` reach the document, and no
///    navigation happens (measured: `performance.getEntriesByType('navigation')`
///    is unchanged across a patch);
///  * `document.head` keeps exactly the load-time policy meta, and the copies
///    riding along in the fragment land in the body;
///  * an offline document stays cut off from the network after a patch
///    (`fetch` rejects).
///
/// The two that remain never flaked in any run — and they are the ones that
/// would matter if the patch script were ever refactored.
@MainActor
final class MiniAppPreviewPatchWebKitTests: XCTestCase {

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Nothing here needs to persist, and the default store is global to the
        // process — the sweep tests enumerate exactly that state, so a patch
        // test must not leave anything of itself in it.
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 640),
                         configuration: configuration)
    }

    private func load(_ webView: WKWebView, body: String) async {
        webView.loadHTMLString(Sandbox.harden(body, capability: .offline), baseURL: nil)
        _ = await eventually(webView, "document.readyState === 'complete' ? 1 : null")
    }

    private func patch(_ webView: WKWebView, body: String) async {
        let hardened = Sandbox.harden(body, capability: .offline)
        guard let script = MiniAppPreviewStream.patchScript(hardenedHTML: hardened) else {
            return XCTFail("no patch script for a non-empty document")
        }
        _ = try? await webView.evaluateJavaScript(script)
    }

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

    /// A half-written `<script>` must never run. It would install timers and
    /// listeners that outlive the patch replacing its markup, and every later
    /// patch would install them again.
    func testPatchNeverRunsScriptTags() async {
        let webView = makeWebView()
        await load(webView, body: "<script>window.__ran = 0;</script><p>x</p>")

        await patch(webView, body: "<script>window.__ran = (window.__ran||0) + 1;</script><p>y</p>")

        _ = await eventually(webView, "document.body.textContent.indexOf('y') >= 0 ? 1 : null")
        let ran = try? await webView.evaluateJavaScript("window.__ran")
        XCTAssertEqual(ran as? Int, 0, "a script tag in a streamed chunk must not execute")
    }

    /// Inline handlers are the leak `<script>`-stripping alone does not close:
    /// `innerHTML` never runs script TAGS, but an `onerror`/`onload` attribute
    /// fires the moment the element is inserted into the live document — and
    /// every tier's CSP carries `script-src 'unsafe-inline'`, so nothing else
    /// stops it. At ~4 patches a second that is the same handler firing over
    /// and over while the model is still writing it.
    func testPatchNeverRunsInlineEventHandlers() async {
        let webView = makeWebView()
        await load(webView, body: "<script>window.__fired = 0;</script><p>x</p>")

        await patch(webView, body: "<img src=x onerror=\"window.__fired = (window.__fired||0) + 1\"><p>y</p>")

        _ = await eventually(webView, "document.body.textContent.indexOf('y') >= 0 ? 1 : null")
        // Give a failing image load time to report; the assertion is about the
        // handler never running, so it has to be given the chance to run.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let fired = try? await webView.evaluateJavaScript("window.__fired")
        XCTAssertEqual(fired as? Int, 0, "an inline handler in a streamed chunk must not execute")
    }
}
