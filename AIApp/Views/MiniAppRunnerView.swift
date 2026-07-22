import SwiftUI
import WebKit
import UIKit

/// Runs one mini-app in a sandboxed WKWebView. Capability controls CSP and
/// whether top-level navigation / frames are allowed.
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
        // Browser tier may load remote frames; still no free-for-all cookies.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.capability = capability
        webView.loadHTMLString(Sandbox.harden(html, capability: capability), baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.capability = capability
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            webView.loadHTMLString(Sandbox.harden(html, capability: capability), baseURL: nil)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let appId: String
        var capability: MiniAppCapability
        weak var webView: WKWebView?
        var loadedHTML: String?

        init(appId: String, capability: MiniAppCapability) {
            self.appId = appId
            self.capability = capability
        }

        private var storageKeyPrefix: String { "miniapp-storage-\(appId)-" }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            if scheme == nil || scheme == "about" || scheme == "data" {
                decisionHandler(.allow)
                return
            }
            // Browser capability: allow in-webview http(s) navigations.
            if capability.allowsTopLevelNavigation,
               scheme == "http" || scheme == "https" {
                decisionHandler(.allow)
                return
            }
            // Otherwise: user taps open in Safari; scripts cannot navigate away.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url, scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if capability.allowsTopLevelNavigation,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                webView.load(URLRequest(url: url))
                return nil
            }
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
            }
            return nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "bridge",
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
                if let urlString = payload["url"] as? String,
                   let url = URL(string: urlString),
                   let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    await MainActor.run { UIApplication.shared.open(url) }
                    return ["ok": true]
                }
                return ["ok": false, "error": "invalid_url"]
            default:
                return NSNull()
            }
        }
    }
}
