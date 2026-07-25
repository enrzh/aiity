import SwiftUI
import WebKit
import UIKit

/// Runs one mini-app in a sandboxed WKWebView. Capability controls CSP and
/// whether top-level navigation / frames are allowed.
///
/// Security model: the native `bridge` (storage/health/notify/openExternal) is
/// served ONLY while the web view is showing our trusted, CSP-hardened initial
/// document. The moment the page navigates to remote or `data:` content (browser
/// tier), the bridge is disabled so a remote/injected page cannot reach native
/// capabilities by posting to `webkit.messageHandlers.bridge` directly.
struct MiniAppRunnerView: UIViewRepresentable {
    let appId: String
    let html: String
    var capability: MiniAppCapability = .offline

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
        webView.loadHTMLString(Sandbox.harden(html, capability: capability), baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let capabilityChanged = context.coordinator.capability != capability
        context.coordinator.capability = capability
        if context.coordinator.loadedHTML != html || capabilityChanged {
            context.coordinator.loadedHTML = html
            context.coordinator.beginTrustedLoad()
            webView.loadHTMLString(Sandbox.harden(html, capability: capability), baseURL: nil)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
    }

    /// Stable per-app data-store id for persistent browser sessions (iOS 17+).
    static func sessionStoreID(for appId: String) -> UUID {
        UUID(uuidString: appId) ?? UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!
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

            // Browser tier may load remote content, but once the main frame leaves
            // our trusted document the bridge stops trusting the page.
            if capability.allowsTopLevelNavigation, isRemote {
                if isMainFrame { bridgeActive = false }
                decisionHandler(.allow)
                return
            }

            // Everything else — offline/network remote nav, any `data:` top-level
            // load, other schemes — never navigates the sandbox. A user-tapped
            // link opens in Safari instead; scripts cannot navigate away.
            if isMainFrame, isRemote, navigationAction.navigationType == .linkActivated, let url {
                UIApplication.shared.open(url)
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
                bridgeActive = false
                webView.load(URLRequest(url: url))
            } else if navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
            }
            return nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Remote/untrusted page (browser tier navigated away): no native bridge.
            guard bridgeActive,
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
            case "health.query":
                return await MiniAppHealthService.query(
                    type: payload["type"] as? String ?? "",
                    days: (payload["days"] as? NSNumber)?.intValue ?? 7
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

        /// Native confirmation before leaving the app for Safari.
        @MainActor
        private func confirmOpenExternal(_ url: URL) async -> Bool {
            guard let presenter = webView?.window?.rootViewController?.topmostPresented else { return false }
            let host = url.host ?? url.absoluteString
            return await withCheckedContinuation { continuation in
                var resumed = false
                func finish(_ value: Bool) { if !resumed { resumed = true; continuation.resume(returning: value) } }
                let alert = UIAlertController(
                    title: "Im Browser öffnen?",
                    message: host,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in finish(false) })
                alert.addAction(UIAlertAction(title: "Öffnen", style: .default) { _ in finish(true) })
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
