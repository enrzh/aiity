import Foundation

/// The decisions the mini-app runner's web view makes about one navigation.
///
/// Split out of `MiniAppRunnerView.Coordinator` so the rules are testable
/// without fabricating `WKNavigationAction`s (which cannot be constructed
/// outside WebKit). The Coordinator translates a real navigation into these
/// inputs, applies the decision, and owns nothing but the side effects.
enum BrowserNavigationDecision: Equatable {
    /// Let WebKit load it.
    case allow
    /// Refuse it; nothing else happens.
    case cancel
    /// Refuse the load and turn it into a `WKDownload`.
    case download
    /// Refuse the load and offer to hand the URL to the system (Safari, Mail,
    /// Phone, another app's OAuth callback) after the usual confirmation.
    case openExternally(URL)
    /// Refuse the load and run one of our own error page's buttons.
    case internalAction(BrowserRunnerAction)
}

/// The buttons the runner's own error page offers. They travel as
/// `aiity-runner://<action>` links because the error page is a null-origin
/// document with `default-src 'none'` and no bridge — a link is the one channel
/// that survives that hardening.
enum BrowserRunnerAction: String, Equatable {
    case retry
    case safari
}

enum BrowserNavigationPolicy {

    /// Scheme reserved for the runner's own error page. It is deliberately NOT
    /// registered in `CFBundleURLTypes`: it never leaves `decidePolicyFor`.
    static let internalScheme = "aiity-runner"

    /// Schemes that are never handed to the system, whatever the tier.
    ///
    /// `data:` and `javascript:` are the classic sandbox-escape schemes;
    /// `file:` would hand out the app container. The web schemes are handled
    /// earlier and listed here so a fall-through can never leak them into the
    /// system-handoff branch.
    private static let neverHandedOff: Set<String> = [
        "data", "javascript", "file", "blob", "http", "https", "about", "ws", "wss", internalScheme,
    ]

    /// - Parameters:
    ///   - isLinkActivated: WebKit's `.linkActivated` navigation type. Only used
    ///     by the non-browser tiers, whose links may leave for Safari. Custom
    ///     schemes are routed for EVERY navigation type, because a server 302
    ///     into an OAuth callback scheme arrives as `.other`.
    ///   - isShowingErrorPage: gates `aiity-runner://` so a remote page that
    ///     merely contains such a link cannot drive the error page's buttons.
    static func decide(url: URL?,
                       capability: MiniAppCapability,
                       isMainFrame: Bool,
                       isLinkActivated: Bool,
                       shouldPerformDownload: Bool,
                       isShowingErrorPage: Bool,
                       allowedHosts: Set<String> = []) -> BrowserNavigationDecision {
        let scheme = url?.scheme?.lowercased()

        if scheme == internalScheme {
            guard isShowingErrorPage,
                  let action = url?.host.flatMap(BrowserRunnerAction.init(rawValue:)) else { return .cancel }
            return .internalAction(action)
        }

        // Same-document / in-memory (fragment links, about:blank) — harmless.
        if scheme == nil || scheme == "about" { return .allow }

        let isWeb = scheme == "http" || scheme == "https"

        if isWeb, let url,
           !NetworkTargetValidator.isAllowed(url, allowPrivate: false,
                                             allowedHosts: Array(allowedHosts)) {
            return .cancel
        }

        guard capability.allowsTopLevelNavigation else {
            // Offline/network tiers never navigate the sandbox. A user-tapped
            // web link may still leave for Safari — after the same confirmation
            // the `open.external` bridge action requires, so a scripted
            // `a.click()` cannot exfiltrate silently.
            if isMainFrame, isWeb, isLinkActivated, let url { return .openExternally(url) }
            return .cancel
        }

        if isWeb {
            // Every hop, including the ones inside a popup, goes through the
            // same SSRF gate the initial target does.
            return shouldPerformDownload ? .download : .allow
        }

        // `<a download>` and generated files produce blob: URLs; they are
        // same-origin to the page that made them and carry no network reach.
        if scheme == "blob" { return shouldPerformDownload ? .download : .allow }

        // tel:, mailto:, sms:, maps:, and the custom schemes OAuth providers
        // redirect to when they hand control back to a native app.
        if isMainFrame, let url, let scheme, !neverHandedOff.contains(scheme) {
            return .openExternally(url)
        }
        return .cancel
    }
}

/// One-shot http fallback for a site that only exists over cleartext.
///
/// Deliberately narrow: it applies only when the user typed a bare host (so we
/// were the ones who assumed https), only to public hosts, and only once per
/// runner — otherwise it would be a downgrade attack surface rather than a
/// convenience.
enum BrowserRetryPolicy {

    /// Failures a different scheme could plausibly fix.
    static let retriableCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
    ]

    static func httpFallbackURL(for failedURL: URL,
                                errorCode: Int,
                                schemeWasAssumed: Bool,
                                alreadyRetried: Bool,
                                allowedHosts: [String]? = nil) -> URL? {
        guard schemeWasAssumed, !alreadyRetried else { return nil }
        guard failedURL.scheme?.lowercased() == "https" else { return nil }
        guard retriableCodes.contains(errorCode) else { return nil }
        var components = URLComponents(url: failedURL, resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        guard let http = components?.url else { return nil }
        let allowed = if let allowedHosts {
            NetworkTargetValidator.isAllowed(http, allowPrivate: false, allowedHosts: allowedHosts)
        } else {
            NetworkTargetValidator.isAllowed(http, allowPrivate: false)
        }
        guard allowed else { return nil }
        return http
    }
}

/// Detects a provider deliberately refusing to serve an embedded browser.
///
/// Google answers OAuth inside a WKWebView with `disallowed_useragent`. That is
/// a policy decision on their side, not a bug on ours: the app does NOT imitate
/// Safari to get around it. It recognises the refusal and offers to finish the
/// sign-in in the real browser instead.
enum EmbeddedBrowserRefusal {

    static func isRefusal(url: URL, statusCode: Int?) -> Bool {
        if url.absoluteString.lowercased().contains("disallowed_useragent") { return true }
        guard let host = url.host?.lowercased() else { return false }
        let isGoogleSignIn = host == "accounts.google.com"
            || host.hasSuffix(".accounts.google.com")
            || host == "accounts.youtube.com"
        guard isGoogleSignIn else { return false }
        let path = url.path.lowercased()
        if path.contains("/signin/rejected") { return true }
        if statusCode == 403,
           path.hasPrefix("/o/oauth2/") || path.hasPrefix("/signin/oauth") || path.hasPrefix("/v3/signin") {
            return true
        }
        return false
    }
}
