import SwiftUI
import WebKit
import UIKit

/// Runs one mini-app in a sandboxed WKWebView. Capability controls CSP and
/// whether top-level navigation / frames are allowed.
///
/// Security model: the native `bridge` (storage/notify/openExternal) is
/// served ONLY while the web view is showing our trusted, CSP-hardened initial
/// document. The moment the page navigates to remote or `data:` content (browser
/// tier), the bridge is disabled so a remote/injected page cannot reach native
/// capabilities by posting to `webkit.messageHandlers.bridge` directly.
///
/// The browser tier additionally has to behave like a browser, not just like a
/// sandbox: popups, JS dialogs, downloads, `tel:`/`mailto:`/OAuth-callback
/// schemes, load errors and back navigation all have explicit handling below.
/// Every one of those paths still runs the same `NetworkTargetValidator` gate,
/// and none of them grants the bridge.
/// Back navigation for the browser tier, published to the hosting sheet.
///
/// The edge-swipe alone is not enough: inside a presented sheet the system's own
/// edge handling competes with WebKit's, so a user who follows a link can end up
/// with no way back at all. The sheet renders a real button from this.
@MainActor
final class MiniAppBrowserState: ObservableObject {
    @Published var canGoBack = false
    fileprivate weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
}

struct MiniAppRunnerView: UIViewRepresentable {
    let appId: String
    let html: String
    var capability: MiniAppCapability = .offline
    /// Set by the hosting sheet when it wants a back button.
    var browserState: MiniAppBrowserState? = nil

    /// A browser app that only exists to open a site loads that site as its
    /// document. Rendering the shell first cannot work: it has a null origin and
    /// a `default-src 'none'` CSP, so its script is not permitted to navigate
    /// away — which is why sites like x.com never appeared.
    private func load(into webView: WKWebView) {
        // The target comes out of model-authored HTML, so it is validated like
        // any other model-chosen URL: http(s) only, never a private/LAN address.
        if capability == .browser, let target = WebAppBuilder.openTarget(in: html) {
            guard NetworkTargetValidator.isAllowed(
                target, allowPrivate: false,
                allowedHosts: MiniAppConsent.hosts(appId: appId)
            ) else {
                // Refused. Do NOT fall through to the generated shell: it
                // contains `location.replace(<target>)` for this exact URL, so
                // rendering it would perform the navigation just refused.
                webView.loadHTMLString(Sandbox.harden(Self.refusedHTML(target), capability: .offline), baseURL: nil)
                return
            }
            // The document is now a REMOTE page, so it must never be treated as
            // our trusted shell: the native bridge stays off. `beginTrustedLoad`
            // turned it on for the shell case — undo that here rather than let
            // x.com inherit storage/notify/openExternal.
            webView.load(URLRequest(url: target))
            return
        }
        webView.loadHTMLString(
            Sandbox.harden(html, capability: capability, allowedHosts: MiniAppConsent.hosts(appId: appId)),
            baseURL: nil
        )
    }

    /// Shown instead of the generated shell when its target is not permitted.
    static func refusedHTML(_ target: URL) -> String {
        let host = (target.host ?? target.absoluteString)
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <p style="font:15px/1.5 -apple-system,sans-serif;color:#888;padding:24px">
        Diese Mini-App wollte <b>\(host)</b> öffnen. Das ist eine Adresse im
        lokalen Netzwerk und wird nicht geladen.
        </p>
        """
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(appId: appId, capability: capability)
    }

    func makeUIView(context: Context) -> WKWebView {
        // The data store below is chosen before the web view exists, so the
        // class API runs first here too. Same guard as everywhere else — see
        // WebKitRuntime for why WebKit's class APIs need one at all.
        WebKitRuntime.ensureInitialised()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "bridge")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // WebKit's popup blocker is on by default, and it drops any
        // `window.open` that is not still inside a user gesture. OAuth SDKs
        // routinely open their window after an await, so the sign-in window
        // simply never appeared. The popup lands in its own sheet with the
        // host shown, with no bridge and the same validator on every hop —
        // and only for a tier the user explicitly consented to.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = capability.allowsTopLevelNavigation
        // A browser-tier app keeps a persistent, per-app session so the user
        // stays logged in to the site it opens; other tiers stay ephemeral.
        // Based on ALREADY-GRANTED consent (readable synchronously) rather than
        // the live `capability`, which is still .offline while the consent alert
        // is up — using that made browser sessions never persist at all. A
        // never-approved app still gets no persistent store.
        //
        // MiniAppSheet gives this view `.id(effectiveCapability)`, so the first
        // grant tears the web view down and re-enters here with the grant
        // already written — otherwise the very first login's cookies landed in
        // the ephemeral store and were gone on close.
        if MiniAppConsent.granted(appId: appId) == .browser {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.sessionStoreID(for: appId))
        } else {
            configuration.websiteDataStore = .nonPersistent()
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Deep navigation used to be a one-way trip: the sheet has no chrome of
        // its own, so the edge-swipe is the only way back.
        webView.allowsBackForwardNavigationGestures = capability.allowsTopLevelNavigation
        context.coordinator.webView = webView
        context.coordinator.capability = capability
        context.coordinator.schemeWasAssumed = WebAppBuilder.schemeWasAssumed(in: html)
        context.coordinator.bind(browserState, to: webView)
        context.coordinator.beginTrustedLoad()
        load(into: webView)
        if capability == .browser,
           let target = WebAppBuilder.openTarget(in: html),
           NetworkTargetValidator.isAllowed(
                target, allowPrivate: false,
                allowedHosts: MiniAppConsent.hosts(appId: appId)
           ) {
            context.coordinator.initialTarget = target
            context.coordinator.disableBridgeForRemoteDocument()
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let capabilityChanged = context.coordinator.capability != capability
        context.coordinator.capability = capability
        if context.coordinator.loadedHTML != html || capabilityChanged {
            context.coordinator.loadedHTML = html
            context.coordinator.schemeWasAssumed = WebAppBuilder.schemeWasAssumed(in: html)
            webView.allowsBackForwardNavigationGestures = capability.allowsTopLevelNavigation
            context.coordinator.beginTrustedLoad()
            load(into: webView)
            if capability == .browser,
               let target = WebAppBuilder.openTarget(in: html),
               NetworkTargetValidator.isAllowed(
                    target, allowPrivate: false,
                    allowedHosts: MiniAppConsent.hosts(appId: appId)
               ) {
                context.coordinator.initialTarget = target
                context.coordinator.disableBridgeForRemoteDocument()
            }
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // A focused HTML input must not hold its keyboard through sheet
        // teardown: WKWebView's keyboard-dismissal geometry racing the sheet
        // transition is what left the chat composer's keyboard inset stale.
        webView.endEditing(true)
        coordinator.dismissAllPopups()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
    }

    /// Stable per-app data-store id for persistent browser sessions (iOS 17+).
    /// Per-app cookie jar. Saved apps have UUID ids and keep theirs; a preview
    /// app is keyed by a content hash, which used to fall back to ONE shared
    /// constant — so every previewed browser app saw each other's sessions.
    /// Deriving keeps them isolated while still stable across opens.
    static func sessionStoreID(for appId: String) -> UUID {
        StableIdentifier.uuid(fromPossibleUUID: appId)
    }

    /// Drop a mini-app's persistent cookie jar when the app itself is deleted.
    /// Otherwise its logins outlive it on disk, owned by nothing.
    ///
    /// Returns immediately — deleting a mini-app must stay instant — but never
    /// silently: the identifier is written to `MiniAppSessionStorePurgeQueue`
    /// **before** the attempt, and only a removal WebKit actually accepts takes
    /// it off that list. That ordering is the whole fix. WebKit refuses to
    /// delete a store the current process has opened, which is exactly the
    /// common case (open the browser mini-app, then delete it), and the refusal
    /// used to be discarded by the `{ _ in }` handler that stood here — leaving
    /// real site logins on disk while the app reported the delete as done.
    /// `MiniAppSessionStoreSweep` retries whatever is left on the next launch,
    /// which is a fresh process and therefore able to delete it.
    /// The returned task is the removal in flight. The UI ignores it — that is
    /// the point of returning rather than awaiting — but a test must be able to
    /// wait for it: an unsequenced WebKit removal outlives the test that started
    /// it and materialises a data store directory in the middle of the next one.
    @discardableResult
    static func removeSessionStore(for appId: String) -> Task<Bool, Never> {
        let identifier = sessionStoreID(for: appId)
        // Durable first, and synchronously: a kill between the tap and the
        // removal must leave the app knowing it still owes this deletion.
        MiniAppSessionStorePurgeQueue.note(identifier)
        // Deleting is the one mini-app action that needs no web view, so this
        // is where WebKit's uninitialised-run-loop segfault actually fired.
        // Brought up here, on the caller's thread, rather than inside the task
        // below — the guard has to be in front of the class API no matter how
        // the task is scheduled. WebKitRuntime carries the full explanation.
        WebKitRuntime.ensureInitialised()
        return Task { @MainActor in
            await purgeSessionStore(identifier)
        }
    }

    /// One removal attempt, awaited, answering whether WebKit accepted it — and
    /// keeping the durable purge queue honest either way. The single deleter of
    /// a persistent store in the app: `MiniAppSessionStoreSweep.StoreIndex`
    /// owns the WebKit call itself, so there is one place where the error is
    /// read and one place where the fatal-without-initialisation guard lives.
    @MainActor
    @discardableResult
    static func purgeSessionStore(_ identifier: UUID) async -> Bool {
        let accepted = await MiniAppSessionStoreSweep.StoreIndex.webKit.remove(identifier)
        MiniAppSessionStorePurgeQueue.recordAttempt(identifier, succeeded: accepted)
        return accepted
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let appId: String
        var capability: MiniAppCapability
        weak var webView: WKWebView?
        var loadedHTML: String?
        /// The site this browser app exists to open, for the error page's retry.
        var initialTarget: URL?
        /// True when https was OUR assumption (bare host typed) — the only case
        /// in which the one-shot cleartext retry is defensible.
        var schemeWasAssumed = false

        /// The bridge only serves the trusted, CSP-hardened initial document.
        private var bridgeActive = true
        /// True for exactly one navigation: our own `loadHTMLString`.
        private var pendingTrustedLoad = false
        /// True while our own error page is the document — the only time the
        /// `aiity-runner://` action links are honoured.
        private(set) var isShowingErrorPage = false
        /// The URL the error page's buttons act on.
        private var failedURL: URL?
        /// One http fallback per runner, ever. A loop of downgrades is worse
        /// than a page that does not load.
        private var didRetryOverHTTP = false

        /// Popup web views this runner opened, keyed by identity so
        /// `webViewDidClose` can find the right sheet.
        private var popupControllers: [ObjectIdentifier: BrowserPopupViewController] = [:]
        /// How many popups this runner has handed out. A refused `window.open`
        /// must not increment it.
        private(set) var popupsCreated = 0
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]
        private var canGoBackObservation: NSKeyValueObservation?

        init(appId: String, capability: MiniAppCapability) {
            self.appId = appId
            self.capability = capability
        }

        /// Keep the sheet's back button in step with the web view's history.
        @MainActor
        func bind(_ state: MiniAppBrowserState?, to webView: WKWebView) {
            guard let state else { return }
            state.webView = webView
            state.canGoBack = webView.canGoBack
            canGoBackObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { webView, _ in
                Task { @MainActor in state.canGoBack = webView.canGoBack }
            }
        }

        /// Mark the next navigation as a trusted (app-initiated) document load.
        func beginTrustedLoad() {
            pendingTrustedLoad = true
            bridgeActive = true
        }

        /// App-initiated, but the document is a third-party site — allow the
        /// load without granting it the native bridge.
        func disableBridgeForRemoteDocument() {
            bridgeActive = false
        }

        /// Our own generated page (error/refusal): allowed to load, never
        /// granted the bridge — it needs nothing but links.
        private func beginInternalLoad() {
            pendingTrustedLoad = true
            bridgeActive = false
        }

        private var storageKeyPrefix: String { "miniapp-storage-\(appId)-" }

        // MARK: Navigation policy

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Our own hardened (re)load — the only navigation that keeps the
            // bridge, and only in the PARENT view. A popup must never consume
            // this flag and inherit an unvalidated first hop.
            if pendingTrustedLoad, webView === self.webView {
                pendingTrustedLoad = false
                decisionHandler(.allow)
                return
            }
            let isParent = webView === self.webView
            let url = navigationAction.request.url
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

            let decision = BrowserNavigationPolicy.decide(
                url: url,
                capability: capability,
                isMainFrame: isMainFrame,
                isLinkActivated: navigationAction.navigationType == .linkActivated,
                shouldPerformDownload: navigationAction.shouldPerformDownload,
                isShowingErrorPage: isParent && isShowingErrorPage,
                allowedHosts: Set(MiniAppConsent.hosts(appId: appId))
            )

            switch decision {
            case .allow:
                // A remote main-frame document is never our trusted shell.
                if isParent, isMainFrame, let scheme = url?.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    bridgeActive = false
                    isShowingErrorPage = false
                }
                decisionHandler(.allow)
            case .download:
                decisionHandler(.download)
            case .cancel:
                decisionHandler(.cancel)
            case .openExternally(let target):
                confirmOpenExternal(target)
                decisionHandler(.cancel)
            case .internalAction(let action):
                decisionHandler(.cancel)
                perform(action)
            }
        }

        /// Attachments and any response WebKit cannot render become downloads
        /// instead of a silently cancelled navigation.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let response = navigationResponse.response
            let status = (response as? HTTPURLResponse)?.statusCode
            if webView === self.webView, navigationResponse.isForMainFrame, let url = response.url,
               EmbeddedBrowserRefusal.isRefusal(url: url, statusCode: status) {
                decisionHandler(.cancel)
                showEmbeddedBrowserRefusal(for: url)
                return
            }
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleLoadFailure(webView, error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleLoadFailure(webView, error: error)
        }

        /// A failed load used to render nothing at all — an empty white sheet
        /// with no explanation and no way forward.
        private func handleLoadFailure(_ webView: WKWebView, error: Error) {
            let nsError = error as NSError
            // Our own `.cancel`/`.download` decisions surface as these; they are
            // not failures the user should see.
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == "WebKitErrorDomain", nsError.code == 102 || nsError.code == 101 { return }

            let target = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url ?? initialTarget
            guard webView === self.webView else {
                // A popup that cannot load: show the same page inside it, but
                // without retry/fallback state, which belongs to the runner.
                if let target {
                    webView.loadHTMLString(
                        Sandbox.harden(Self.errorHTML(url: target, message: nsError.localizedDescription,
                                                      note: nil, actions: []), capability: .offline),
                        baseURL: nil
                    )
                }
                return
            }

            if let target,
               let http = BrowserRetryPolicy.httpFallbackURL(
                    for: target,
                    errorCode: nsError.domain == NSURLErrorDomain ? nsError.code : 0,
                    schemeWasAssumed: schemeWasAssumed,
                    alreadyRetried: didRetryOverHTTP,
                    allowedHosts: MiniAppConsent.hosts(appId: appId)
               ) {
                didRetryOverHTTP = true
                bridgeActive = false
                isShowingErrorPage = false
                failedURL = http
                webView.load(URLRequest(url: http))
                return
            }

            failedURL = target
            let note = didRetryOverHTTP
                ? String(localized: "https war nicht erreichbar, http ebenfalls nicht.")
                : nil
            showErrorPage(message: nsError.localizedDescription, note: note,
                          actions: [.retry, .safari])
        }

        // MARK: The runner's own error page

        private func showErrorPage(message: String, note: String?, actions: [BrowserRunnerAction]) {
            guard let webView else { return }
            let html = Self.errorHTML(url: failedURL, message: message, note: note, actions: actions)
            isShowingErrorPage = true
            beginInternalLoad()
            webView.loadHTMLString(Sandbox.harden(html, capability: .offline), baseURL: nil)
        }

        /// Google (and others) deliberately refuse OAuth inside an embedded web
        /// view. aiity does not imitate Safari's user agent to get around that —
        /// that would be circumventing their policy. It says what happened and
        /// offers the one thing that actually works: finish the sign-in in the
        /// real browser.
        private func showEmbeddedBrowserRefusal(for url: URL) {
            failedURL = url
            showErrorPage(
                message: String(localized: "Dieser Anbieter erlaubt die Anmeldung nicht in einer eingebetteten Ansicht."),
                note: String(localized: "Melde dich in Safari an und öffne die Seite danach wieder hier — die Sitzung bleibt in dieser Mini-App gespeichert."),
                actions: [.safari, .retry]
            )
        }

        private func perform(_ action: BrowserRunnerAction) {
            switch action {
            case .retry:
                guard let webView, let url = failedURL ?? initialTarget,
                      NetworkTargetValidator.isAllowed(
                        url, allowPrivate: false,
                        allowedHosts: MiniAppConsent.hosts(appId: appId)
                      ) else { return }
                isShowingErrorPage = false
                bridgeActive = false
                webView.load(URLRequest(url: url))
            case .safari:
                guard let url = failedURL ?? initialTarget,
                      NetworkTargetValidator.isAllowed(
                        url, allowPrivate: false,
                        allowedHosts: MiniAppConsent.hosts(appId: appId)
                      ) else { return }
                confirmOpenExternal(url)
            }
        }

        static func errorHTML(url: URL?, message: String, note: String?, actions: [BrowserRunnerAction]) -> String {
            func esc(_ s: String) -> String {
                s.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
            let host = url?.host ?? url?.absoluteString ?? ""
            let scheme = BrowserNavigationPolicy.internalScheme
            let buttons = actions.map { action -> String in
                let title: String
                switch action {
                case .retry: title = String(localized: "Erneut versuchen")
                case .safari: title = String(localized: "In Safari öffnen")
                }
                return "<a class=\"b\" href=\"\(scheme)://\(action.rawValue)\">\(esc(title))</a>"
            }.joined()
            let noteHTML = note.map { "<p class=\"n\">\(esc($0))</p>" } ?? ""
            return """
            <style>
            :root{color-scheme:light dark}
            body{margin:0;font:16px/1.5 -apple-system,system-ui,sans-serif;padding:40px 24px;text-align:center;color:#8a8a8e}
            h1{font-size:17px;color:#48484a;margin:0 0 6px}
            .h{font-weight:600;color:#636366}
            .n{font-size:14px}
            .b{display:inline-block;margin:8px 6px 0;padding:11px 18px;border-radius:11px;background:#0a84ff;color:#fff;text-decoration:none;font-size:15px;font-weight:600}
            .b+.b{background:rgba(120,120,128,.18);color:#0a84ff}
            @media (prefers-color-scheme:dark){h1{color:#d1d1d6}.h{color:#aeaeb2}}
            </style>
            <h1>\(esc(String(localized: "Seite konnte nicht geladen werden")))</h1>
            <p class="h">\(esc(host))</p>
            <p>\(esc(message))</p>
            \(noteHTML)
            <p>\(buttons)</p>
            """
        }

        // MARK: Popups (window.open, target=_blank, OAuth sign-in windows)

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased()
            let isWeb = scheme == "http" || scheme == "https"

            if isWeb, let url,
               !NetworkTargetValidator.isAllowed(
                    url, allowPrivate: false,
                    allowedHosts: MiniAppConsent.hosts(appId: appId)
               ) {
                return nil
            }

            guard capability.allowsTopLevelNavigation else {
                // Same rule for `target="_blank"` on the sandboxed tiers:
                // confirm before leaving.
                if isWeb, let url, navigationAction.navigationType == .linkActivated {
                    confirmOpenExternal(url)
                }
                return nil
            }
            if let url, !isWeb, scheme != nil, scheme != "about" {
                // A popup straight into a custom scheme is a handoff, not a page.
                confirmOpenExternal(url)
                return nil
            }
            // Everything else — including `window.open('')` / about:blank, which
            // is what OAuth SDKs actually do — gets a real child web view. It
            // MUST be built from the passed configuration (WebKit requirement,
            // and what keeps window.opener/postMessage and the cookie jar).
            let child = makeChildWebView(configuration: configuration)
            presentPopup(child)
            return child
        }

        /// The child of a browser-tier app. Two invariants, both load-bearing:
        ///
        /// 1. It shares the parent's `userContentController`, so the bridge
        ///    message handler is physically reachable from it. `acceptsBridgeMessage`
        ///    therefore checks web-view IDENTITY, not just the `bridgeActive`
        ///    flag — otherwise a browser app showing its own trusted home screen
        ///    could `window.open` a remote page that posts to the bridge.
        /// 2. It gets this same Coordinator as `uiDelegate`, so the
        ///    capture/motion deny policy applies to it exactly as to the parent.
        func makeChildWebView(configuration: WKWebViewConfiguration) -> WKWebView {
            popupsCreated += 1
            let child = WKWebView(frame: .zero, configuration: configuration)
            child.navigationDelegate = self
            child.uiDelegate = self
            child.allowsBackForwardNavigationGestures = true
            child.isOpaque = false
            return child
        }

        private func presentPopup(_ child: WKWebView) {
            guard let presenter = webView?.window?.rootViewController?.topmostPresented else { return }
            let controller = BrowserPopupViewController(webView: child)
            controller.onClose = { [weak self] in
                self?.popupControllers.removeValue(forKey: ObjectIdentifier(child))
            }
            popupControllers[ObjectIdentifier(child)] = controller
            presenter.present(controller, animated: true)
        }

        /// OAuth popups finish by calling `window.close()`.
        func webViewDidClose(_ webView: WKWebView) {
            guard let controller = popupControllers.removeValue(forKey: ObjectIdentifier(webView)) else { return }
            controller.dismiss(animated: true)
        }

        func dismissAllPopups() {
            for (_, controller) in popupControllers { controller.dismiss(animated: false) }
            popupControllers.removeAll()
        }

        // MARK: WKUIDelegate permission policy
        //
        // Sandboxed mini-apps and browser-tier remote sites must never reach
        // the camera, microphone or motion sensors. The app declares no
        // NSCamera/NSMicrophoneUsageDescription, so leaving WebKit's default
        // (`.prompt`) in place would surface an OS dialog in aiity's name at
        // best and trip a TCC crash on grant at worst. Denying here makes
        // "no capture from web content" an explicit policy instead of an
        // undefined default; sites see an ordinary NotAllowedError.
        //
        // Popups are covered because they are handed this same Coordinator.

        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        func webView(_ webView: WKWebView,
                     requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        // MARK: JS dialogs
        //
        // Without these, WebKit's default is "no dialog": alert() is a no-op,
        // confirm() returns false and prompt() returns nil, so ordinary pages
        // silently take their cancel branch. Every handler MUST call its
        // completion — including the no-presenter case, or the WebContent
        // process hangs waiting for an answer that never comes.

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            guard let presenter = presenter(for: webView) else { completionHandler(); return }
            let alert = UIAlertController(title: dialogTitle(frame), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler() })
            presenter.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            guard let presenter = presenter(for: webView) else { completionHandler(false); return }
            var answered = false
            func finish(_ value: Bool) { if !answered { answered = true; completionHandler(value) } }
            let alert = UIAlertController(title: dialogTitle(frame), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Abbrechen"), style: .cancel) { _ in finish(false) })
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in finish(true) })
            presenter.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            guard let presenter = presenter(for: webView) else { completionHandler(nil); return }
            var answered = false
            func finish(_ value: String?) { if !answered { answered = true; completionHandler(value) } }
            let alert = UIAlertController(title: dialogTitle(frame), message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: String(localized: "Abbrechen"), style: .cancel) { _ in finish(nil) })
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { [weak alert] _ in
                finish(alert?.textFields?.first?.text ?? "")
            })
            presenter.present(alert, animated: true)
        }

        /// Name the origin that is talking, so a framed third party cannot pass
        /// its dialog off as the app's own.
        private func dialogTitle(_ frame: WKFrameInfo) -> String {
            frame.request.url?.host ?? String(localized: "Mini-App")
        }

        private func presenter(for webView: WKWebView) -> UIViewController? {
            (webView.window ?? self.webView?.window)?.rootViewController?.topmostPresented
        }

        // MARK: Downloads

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            // A server-supplied filename is untrusted text: take the last path
            // component only, so "../../Library/Preferences/x" cannot escape.
            var name = (suggestedFilename as NSString).lastPathComponent
            if name.isEmpty || name == "." || name == ".." { name = "Download" }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("miniapp-downloads/\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                completionHandler(nil)
                return
            }
            let destination = directory.appendingPathComponent(name)
            downloadDestinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let file = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)),
                  let presenter = webView?.window?.rootViewController?.topmostPresented else { return }
            let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = presenter.view
            share.popoverPresentationController?.sourceRect = CGRect(
                x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 40, width: 1, height: 1
            )
            presenter.present(share, animated: true)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
            guard let presenter = webView?.window?.rootViewController?.topmostPresented else { return }
            let alert = UIAlertController(
                title: String(localized: "Download fehlgeschlagen"),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            presenter.present(alert, animated: true)
        }

        // MARK: Bridge

        /// Whether a bridge message may be served.
        ///
        /// Identity matters as much as the flag: a popup shares the parent's
        /// `userContentController`, so `bridgeActive` alone would let a remote
        /// popup opened from a trusted home screen reach storage, notifications
        /// and openExternal.
        func acceptsBridgeMessage(from source: WKWebView?, isMainFrame: Bool) -> Bool {
            guard bridgeActive, isMainFrame, let source, let webView else { return false }
            return source === webView
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Remote/untrusted page (browser tier navigated away): no native bridge.
            //
            // `isMainFrame` is load-bearing, not defensive noise: a browser-tier
            // app keeps bridgeActive while OUR document is the main frame, but it
            // may embed <iframe src="https://…">. Without this check any
            // cross-origin frame could post to the bridge and reach storage,
            // notifications and openExternal — a full sandbox escape via an
            // ordinary embed.
            guard acceptsBridgeMessage(from: message.webView, isMainFrame: message.frameInfo.isMainFrame),
                  message.name == "bridge",
                  let body = message.body as? [String: Any],
                  let callId = body["id"] as? Int,
                  let action = body["action"] as? String else { return }
            let payload = body["payload"] as? [String: Any] ?? [:]

            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await self.handle(action: action, payload: payload)
                let resultJSON: String
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    resultJSON = String(decoding: data, as: UTF8.self)
                } else {
                    resultJSON = "null"
                }
                self.webView?.evaluateJavaScript("window.miniapp._resolve(\(callId), \(resultJSON));", completionHandler: nil)
            }
        }

        @MainActor
        private func handle(action: String, payload: [String: Any]) async -> Any {
            switch action {
            case "storage.get":
                if let key = payload["key"] as? String,
                   let stored = UserDefaults.standard.string(forKey: storageKeyPrefix + key),
                   let parsed = try? JSONSerialization.jsonObject(with: Data(stored.utf8), options: [.fragmentsAllowed]) {
                    return parsed
                }
                return NSNull()
            case "storage.set":
                if let key = payload["key"] as? String {
                    let value = payload["value"] ?? NSNull()
                    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
                        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: storageKeyPrefix + key)
                        return true
                    }
                }
                return NSNull()
            case "haptic":
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return true
            case "notify.schedule":
                return await MiniAppNotificationService.schedule(
                    title: payload["title"] as? String ?? "",
                    body: payload["body"] as? String ?? "",
                    inSeconds: (payload["inSeconds"] as? NSNumber)?.doubleValue ?? 1
                )
            case "open.external":
                // Opening Safari is a user-visible action — always confirm so a
                // generated/injected app can't silently exfiltrate via the URL.
                guard let urlString = payload["url"] as? String,
                      let url = URL(string: urlString),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https",
                      NetworkTargetValidator.isAllowed(
                        url, allowPrivate: false,
                        allowedHosts: MiniAppConsent.hosts(appId: appId)
                      ) else {
                    return ["ok": false, "error": "invalid_url"]
                }
                let confirmed = await confirmOpenExternal(url)
                if confirmed { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
                return ["ok": confirmed]
            default:
                return NSNull()
            }
        }

        /// Confirm, then open. For the navigation-policy call sites, which are
        /// synchronous and must not leave the app on their own — every route to
        /// Safari goes through the same prompt as the bridge action.
        @MainActor
        func confirmOpenExternal(_ url: URL) {
            Task { @MainActor in
                if await confirmOpenExternal(url) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
        }

        /// Native confirmation before leaving the app for Safari.
        @MainActor
        private func confirmOpenExternal(_ url: URL) async -> Bool {
            guard let presenter = webView?.window?.rootViewController?.topmostPresented else { return false }
            let host = url.host ?? url.absoluteString
            return await withCheckedContinuation { continuation in
                var resumed = false
                func finish(_ value: Bool) { if !resumed { resumed = true; continuation.resume(returning: value) } }
                let alert = UIAlertController(
                    title: String(localized: "Im Browser öffnen?"),
                    message: host,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "Abbrechen"), style: .cancel) { _ in finish(false) })
                alert.addAction(UIAlertAction(title: String(localized: "Öffnen"), style: .default) { _ in finish(true) })
                presenter.present(alert, animated: true)
            }
        }
    }
}

private extension UIViewController {
    var topmostPresented: UIViewController {
        var vc: UIViewController = self
        while let presented = vc.presentedViewController { vc = presented }
        return vc
    }
}
