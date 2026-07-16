import SwiftUI
import WebKit
import UIKit

/// Runs one mini-app in a sandboxed WKWebView. The bridge handler is the only
/// door out of the sandbox: per-app namespaced storage and a haptic tap.
struct MiniAppRunnerView: UIViewRepresentable {
    let appId: String
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator(appId: appId) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "bridge")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView
        webView.loadHTMLString(Sandbox.harden(html), baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            webView.loadHTMLString(Sandbox.harden(html), baseURL: nil)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let appId: String
        weak var webView: WKWebView?
        var loadedHTML: String?

        init(appId: String) { self.appId = appId }

        private var storageKeyPrefix: String { "miniapp-storage-\(appId)-" }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "bridge",
                  let body = message.body as? [String: Any],
                  let callId = body["id"] as? Int,
                  let action = body["action"] as? String else { return }
            let payload = body["payload"] as? [String: Any] ?? [:]

            var result: Any = NSNull()
            switch action {
            case "storage.get":
                if let key = payload["key"] as? String,
                   let stored = UserDefaults.standard.string(forKey: storageKeyPrefix + key),
                   let parsed = try? JSONSerialization.jsonObject(with: Data(stored.utf8), options: [.fragmentsAllowed]) {
                    result = parsed
                }
            case "storage.set":
                if let key = payload["key"] as? String {
                    let value = payload["value"] ?? NSNull()
                    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
                        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: storageKeyPrefix + key)
                        result = true
                    }
                }
            case "haptic":
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                result = true
            default:
                break
            }

            let resultJSON: String
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                resultJSON = String(decoding: data, as: UTF8.self)
            } else {
                resultJSON = "null"
            }
            webView?.evaluateJavaScript("window.miniapp._resolve(\(callId), \(resultJSON));")
        }
    }
}

/// Full-screen presentation of a mini-app with a close bar.
struct MiniAppSheet: View {
    let appId: String
    let name: String
    let html: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MiniAppRunnerView(appId: appId, html: html)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Fertig") { dismiss() }
                    }
                }
        }
    }
}
