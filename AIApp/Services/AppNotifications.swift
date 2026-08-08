import Foundation
import UserNotifications

/// App-wide notification policy: every OS permission dialog must be the direct
/// result of a user action while the app is in the FOREGROUND. Background code
/// paths never call requestAuthorization — the system cannot present the
/// first-time dialog there, so the notification would be silently lost and the
/// user would later face a context-free permission prompt (exactly the
/// Guideline 5.1.1 "prompt in context" pattern reviewers flag).
enum NotificationGate {
    /// What a call site is allowed to do given the current authorization status.
    enum Decision: Equatable {
        /// Authorization exists (full, provisional or ephemeral): post
        /// directly and never touch requestAuthorization again.
        case post
        /// Never asked. A foreground, user-triggered call site may show the
        /// OS dialog now; a background call site must give up instead.
        case ask
        /// The user declined (or the status is unknown): never re-prompt,
        /// surface the denial to the caller.
        case refuse
    }

    static func decision(for status: UNAuthorizationStatus) -> Decision {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .post
        case .notDetermined:
            return .ask
        case .denied:
            return .refuse
        @unknown default:
            return .refuse
        }
    }
}

enum AppNotifications {
    /// The one gate both notification producers (agent completion and the
    /// mini-app bridge) consult before posting or prompting — keeping two
    /// requestAuthorization sites from double-prompting each other.
    static func gate() async -> NotificationGate.Decision {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationGate.decision(for: settings.authorizationStatus)
    }
}

/// The app's one and only UNUserNotificationCenterDelegate.
///
/// Without a delegate, iOS suppresses every notification that fires while the
/// app is in the foreground — which is precisely when a mini-app's short-timer
/// notify() lands (minimum trigger is 1s), so the feature looked broken in its
/// primary path. Installed once at launch. Anything else that wants delegate
/// callbacks must extend THIS type: UNUserNotificationCenter keeps exactly one
/// delegate and the last setter wins silently.
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationDelegate()

    static func install() {
        // The center holds its delegate weakly; `shared` keeps it alive.
        UNUserNotificationCenter.current().delegate = shared
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
