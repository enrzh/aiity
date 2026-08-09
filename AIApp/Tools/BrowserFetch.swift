import Foundation
import WebKit

/// Loads a page in a real (offscreen) WebKit view and returns its rendered
/// text — what a browser would show, not what the server first sent.
///
/// Two things a plain `URLSession` fetch cannot do, and both bite constantly:
/// pages that build their content with JavaScript come back as an empty shell,
/// and sites that fingerprint non-browser clients serve a block page. WebKit is
/// a browser, so neither applies.
///
/// It is deliberately *not* the default path. A webview costs a process and
/// hundreds of milliseconds where a raw fetch costs neither, so this runs only
/// when the cheap path came back suspiciously thin.
@MainActor
final class BrowserFetch: NSObject {
    /// Give up rather than let a hung page block a tool call forever.
    static let timeout: TimeInterval = 25
    /// After `didFinish`, give client-side rendering a beat to paint. Many
    /// frameworks resolve their first data fetch just after load completes.
    private static let settleDelay: TimeInterval = 1.2

    enum FetchError: LocalizedError {
        case timedOut
        case blockedRedirect(String)
        case navigationFailed(String)
        case noContent

        var errorDescription: String? {
            switch self {
            case .timedOut: return String(localized: "Seite hat nicht rechtzeitig geantwortet.")
            case .blockedRedirect(let host): return String(localized: "Weiterleitung auf eine private Adresse (\(host)) blockiert.")
            case .navigationFailed(let reason): return reason
            case .noContent: return "Seite lieferte keinen lesbaren Text."
            }
        }
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var allowPrivateHosts = false
    private var finished = false

    /// Load `url` and return its visible text.
    /// Compiled once per process. Blocks loads to loopback, link-local and
    /// RFC1918/CGNAT hosts at the WebKit networking layer, which is where
    /// subresources are decided.
    private static var cachedRuleList: WKContentRuleList?

    private static func privateAddressBlockList(allowPrivateHosts: Bool) async -> WKContentRuleList? {
        // When the caller genuinely means to reach a LAN gateway (the user's
        // own Ollama box), blocking it would break the feature.
        guard !allowPrivateHosts else { return nil }
        if let cachedRuleList { return cachedRuleList }

        // url-filter is a regex over the whole URL. These cover the literal
        // forms; a NAME that resolves to a private address is handled before
        // the request is issued, by FetchURLTool.resolvesToPrivateAddress.
        let patterns = [
            "^[^:]+://(localhost|127\\.[0-9.]+|0\\.0\\.0\\.0|\\[::1\\])",
            "^[^:]+://10\\.[0-9]+\\.[0-9]+\\.[0-9]+",
            "^[^:]+://192\\.168\\.[0-9]+\\.[0-9]+",
            "^[^:]+://172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]+\\.[0-9]+",
            "^[^:]+://169\\.254\\.[0-9]+\\.[0-9]+",
            "^[^:]+://100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9]+\\.[0-9]+",
            "^[^:]+://[^/]*\\.(local|internal|lan|home|localdomain)([:/]|$)",
        ]
        let rules = patterns.map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
        let json = "[\(rules.joined(separator: ","))]"

        let compiled = try? await WKContentRuleListStore.default()?
            .compileContentRuleList(forIdentifier: "aiity-block-private", encodedContentRuleList: json)
        cachedRuleList = compiled
        return compiled
    }

    func text(from url: URL, allowPrivateHosts: Bool) async throws -> String {
        // `finished` is one-shot by design; a reused instance would return
        // immediately and never resume its continuation.
        guard !finished, continuation == nil else {
            throw FetchError.navigationFailed(String(localized: "BrowserFetch ist einmal verwendbar."))
        }
        self.allowPrivateHosts = allowPrivateHosts

        // The app's only other entry point where WebKit *class* APIs
        // (`nonPersistent()`, `WKContentRuleListStore.default()`) run before any
        // web view exists — the agent can call fetch_url on a launch that never
        // showed a mini-app. Those two tolerate it today; WKWebsiteDataStore's
        // deletion APIs do not (see WebKitRuntime), so every entry point brings
        // WebKit up the same way instead of depending on which WebKit class
        // happens to self-initialise.
        WebKitRuntime.ensureInitialised()

        let configuration = WKWebViewConfiguration()
        // Non-persistent: a research fetch must not inherit or leave behind the
        // user's cookies, and must not accumulate session state across pages.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // `decidePolicyFor` fires for NAVIGATIONS ONLY. The fetched page's own
        // scripts, images, XHR and WebSockets never reach it, and this view
        // runs their JavaScript with no CSP under an app-wide
        // NSAllowsArbitraryLoads. A page returned by a hostile server could
        // therefore issue `new Image().src = 'http://192.168.1.1/…'` and sweep
        // the user's LAN from their own device — a state-changing request and a
        // port scan driven by content the agent only tried to read. A content
        // rule list is the only hook that covers subresources.
        if let rules = await Self.privateAddressBlockList(allowPrivateHosts: allowPrivateHosts) {
            configuration.userContentController.add(rules)
        }

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1400), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        // Ask for the desktop-ish layout most articles are written for.
        view.customUserAgent = WebSearchTool.browserUA
        webView = view

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.timeout
            view.load(request)

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
                self?.finish(.failure(FetchError.timedOut))
            }
        }
    }

    /// Resolve exactly once and tear the webview down — a live webview left
    /// behind keeps a content process alive.
    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        let pending = continuation
        continuation = nil
        switch result {
        case .success(let text): pending?.resume(returning: text)
        case .failure(let error): pending?.resume(throwing: error)
        }
    }

    private func extractText() {
        // `innerText` is the rendered text — it already excludes script/style
        // and respects display:none, which is why this beats regex-stripping
        // raw HTML. Prefer the article/main element when the page marks one.
        let script = """
        (function () {
          var el = document.querySelector('article') || document.querySelector('main') || document.body;
          if (!el) { return ''; }
          return el.innerText || '';
        })();
        """
        webView?.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(FetchError.navigationFailed(error.localizedDescription)))
                return
            }
            let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.finish(text.isEmpty ? .failure(FetchError.noContent) : .success(text))
        }
    }
}

extension BrowserFetch: WKUIDelegate {
    /// Same deny-by-default policy as MiniAppRunnerView: a page fetched for
    /// reading must never reach capture or motion sensors. This view is
    /// offscreen with no window, so WebKit could not present a prompt anyway —
    /// these turn "cannot present" into stated policy.
    nonisolated func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    nonisolated func webView(
        _ webView: WKWebView,
        requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }
}

extension BrowserFetch: WKNavigationDelegate {
    /// Every hop is re-checked: a public URL can redirect to a LAN address, and
    /// the webview follows redirects on its own.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let host = navigationAction.request.url?.host ?? ""
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        MainActor.assumeIsolated {
            let allowedScheme = ["http", "https", "about", "data", "blob"].contains(scheme)
            let blocked = !allowPrivateHosts && !host.isEmpty && FetchURLTool.isBlockedHost(host)

            // A SUBFRAME is refused on its own; it must not abort the fetch. An
            // ad iframe or a tracking pixel pointing somewhere we won't load is
            // routine, and failing the whole read over it meant ordinary pages
            // came back empty.
            guard isMainFrame else {
                decisionHandler(blocked || !allowedScheme ? .cancel : .allow)
                return
            }
            guard ["http", "https"].contains(scheme) else {
                decisionHandler(.cancel)
                finish(.failure(FetchError.navigationFailed("Nur http(s) erlaubt.")))
                return
            }
            if blocked {
                decisionHandler(.cancel)
                finish(.failure(FetchError.blockedRedirect(host)))
                return
            }
            decisionHandler(.allow)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
                self?.extractText()
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated {
            // Ignore a cancellation we caused ourselves by refusing a subframe.
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            finish(.failure(FetchError.navigationFailed(error.localizedDescription)))
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            finish(.failure(FetchError.navigationFailed(error.localizedDescription)))
        }
    }
}
