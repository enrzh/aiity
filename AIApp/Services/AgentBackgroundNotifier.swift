import Foundation
import UserNotifications

/// The pause alert that fires when iOS takes the background grant back.
///
/// NOTIFICATION POLICY (shipped, must not regress): this runs from a
/// BACKGROUND path, so it never calls `requestAuthorization`. The system
/// cannot present the first-time dialog there — the notification would be lost
/// and the user would later face a context-free permission prompt, which is
/// exactly the Guideline 5.1.1 pattern reviewers flag. The only
/// `requestAuthorization` site for agent notifications stays where it is:
/// `AgentLiveActivityController.start()`, on a user-initiated send while the
/// app is in the foreground.
///
/// So `.ask` — "never asked" — degrades to silence here. The user still gets
/// the truthful Live Activity ("Pausiert — App öffnen") and the in-app resume
/// affordance; those are the fallbacks, not a second prompt.
///
/// Also NOT used: `.timeSensitive`. It needs the
/// `com.apple.developer.usernotifications.time-sensitive` capability and an
/// upgraded grant that provisional authorization does not provide — asserting
/// otherwise would ship an alert that never arrives.
enum AgentBackgroundNotifier {
    /// What the gate permits a background caller to do. Pure, so the policy
    /// itself is testable without driving the process-wide permission state.
    enum Action: Equatable {
        case post(title: String, body: String)
        /// Carries the reason so a test can tell "never asked" from "denied".
        case skip(NotificationGate.Decision)
    }

    /// Test seams.
    static var gateOverride: NotificationGate.Decision?
    static var sinkForTesting: ((String, String) -> Void)?

    static func plan(gate: NotificationGate.Decision, title: String, body: String) -> Action {
        switch gate {
        case .post:
            return .post(title: title, body: body)
        case .ask:
            // Deliberately NOT a requestAuthorization — see the type comment.
            return .skip(.ask)
        case .refuse:
            return .skip(.refuse)
        }
    }

    /// Fire-and-forget: the expiration handler has seconds, not milliseconds
    /// to spare, and must not await a permissions round-trip.
    static func notifyTurnPaused() {
        Task { await postTurnPaused() }
    }

    @discardableResult
    static func postTurnPaused() async -> Action {
        let title = String(localized: "Antwort pausiert")
        let body = String(localized: "iOS hat die Hintergrundzeit beendet. App öffnen, um fortzusetzen.")
        let gate: NotificationGate.Decision
        if let gateOverride {
            gate = gateOverride
        } else {
            gate = await AppNotifications.gate()
        }
        let action = plan(gate: gate, title: title, body: body)
        guard case .post(let postTitle, let postBody) = action else { return action }
        if let sinkForTesting {
            sinkForTesting(postTitle, postBody)
            return action
        }
        let content = UNMutableNotificationContent()
        content.title = postTitle
        content.body = postBody
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "aiity-agent-paused-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
        return action
    }
}
