import Foundation
import UserNotifications

/// Native capabilities exposed to mini-apps through the bridge. Every entry
/// point asks for its system permission on first use and returns a JSON-ready
/// dictionary with {ok, ...} so generated apps can handle denial gracefully.
enum MiniAppNotificationService {
    /// Test seam: unit tests cannot drive the process-wide notification
    /// authorization state, so they inject the gate decision directly.
    static var gateOverride: NotificationGate.Decision?

    static func schedule(title: String, body: String, inSeconds: Double) async -> [String: Any] {
        let center = UNUserNotificationCenter.current()
        let decision: NotificationGate.Decision
        if let gateOverride {
            decision = gateOverride
        } else {
            decision = await AppNotifications.gate()
        }
        switch decision {
        case .post:
            break
        case .ask:
            // First use. The app is foreground by construction — the user is
            // inside a running mini-app — so the OS can present the dialog in
            // context. Follow-up pending product sign-off: generated JS can
            // reach this without a tap; a native pre-confirm in the style of
            // open.external would close that gap, at the price of a double
            // dialog on very first use.
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return ["ok": false, "error": "permission_denied"] }
        case .refuse:
            // Previously denied: requestAuthorization would return false
            // without showing anything anyway — make "never re-prompt"
            // explicit and keep the bridge contract.
            return ["ok": false, "error": "permission_denied"]
        }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Mini-App" : String(title.prefix(80))
        content.body = String(body.prefix(300))
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, inSeconds), repeats: false)
        let id = "miniapp-\(UUID().uuidString)"
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            return ["ok": true, "id": id]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}
