import Foundation
import UserNotifications

/// Native capabilities exposed to mini-apps through the bridge. Every entry
/// point asks for its system permission on first use and returns a JSON-ready
/// dictionary with {ok, ...} so generated apps can handle denial gracefully.
enum MiniAppNotificationService {
    static func schedule(title: String, body: String, inSeconds: Double) async -> [String: Any] {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return ["ok": false, "error": "permission_denied"] }

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
