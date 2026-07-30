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
            case .timedOut: return "Seite hat nicht rechtzeitig geantwortet."
            case .blockedRedirect(let host): return "Weiterleitung auf eine private Adresse (\(host)) blockiert."
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
    func text(from url: URL, allowPrivateHosts: Bool) async throws -> String {
        // `finished` is one-shot by design; a reused instance would return
        // immediately and never resume its continuation.
        guard !finished, continuation == nil else {
            throw FetchError.navigationFailed("BrowserFetch ist einmal verwendbar.")
        }
        self.allowPrivateHosts = allowPrivateHosts

        let configuration = WKWebViewConfiguration()
        // Non-persistent: a research fetch must not inherit or leave behind the
        // user's cookies, and must not accumulate session state across pages.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1400), configuration: configuration)
        view.navigationDelegate = self
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
