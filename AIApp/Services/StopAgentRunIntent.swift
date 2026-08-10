import Foundation
import AppIntents
import ActivityKit

/// The persisted "the user asked to stop" flag.
///
/// It exists because a Live Activity button can be tapped when there is no
/// `ChatSession` to talk to: the app may be suspended, or already terminated
/// by the system. `StopAgentRunIntent.perform()` therefore writes the request
/// down, and the app honours it the next time it comes up.
///
/// IMPORTANT — why `UserDefaults.standard` is enough here: `LiveActivityIntent`
/// is defined by Apple to run **in the containing app's process** (the system
/// resumes a suspended app, or background-launches a terminated one, to run
/// it). It never runs in the widget process, so the app's own defaults are the
/// same defaults the intent writes to and no App Group is required. If anyone
/// ever downgrades `StopAgentRunIntent` to a plain `AppIntent` — which DOES run
/// in the widget process — this flag silently stops crossing the boundary and
/// an App Group container becomes mandatory.
enum AgentRunStopRequest {
    static let defaultsKey = "aiity.stopRequestedAt"

    /// Test seam only. Production always uses `.standard` (see the note above).
    static var store: UserDefaults = .standard

    static func record(at date: Date = Date()) {
        store.set(date.timeIntervalSince1970, forKey: defaultsKey)
    }

    /// The moment the user asked to stop, or nil when nothing is pending.
    static func pendingDate() -> Date? {
        let raw = store.double(forKey: defaultsKey)
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    /// Consume the request. Only the APP may call this — the intent must not,
    /// or the terminated-process cleanup on the next cold launch never runs.
    static func clear() {
        store.removeObject(forKey: defaultsKey)
    }
}

extension Notification.Name {
    /// Posted in the app process by `StopAgentRunIntent`. `ChatSession`
    /// observes it and cancels the running turn immediately when it is alive.
    static let aiityAgentStopRequested = Notification.Name("aiity.agent.stopRequested")
}

/// "Stoppen" on the Lock Screen / in the Dynamic Island.
///
/// Compiled into BOTH the app target and `AIAppLiveActivity` (see project.yml):
/// the widget needs the type to build `Button(intent:)`, the app needs it to
/// actually execute `perform()`. Because of that dual membership this file may
/// only touch API that exists in both — never `ChatSession` or
/// `AgentLiveActivityController`. The notification + flag indirection below is
/// exactly what buys that separation.
///
/// Three cases, all covered:
///  * **App alive (foreground or still-running background task)** — `perform()`
///    runs in-process, the notification is delivered synchronously and
///    `ChatSession.stop()` tears the turn down on the next main-actor tick.
///  * **App suspended** — the system resumes the process to run `perform()`;
///    identical path.
///  * **App terminated** — the system background-launches the app; no SwiftUI
///    scene, so no `ChatSession` observes the notification. The activity
///    teardown below still gives instant Lock Screen feedback, and the
///    persisted flag repairs the conversation on the next real launch.
struct StopAgentRunIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Lauf stoppen"
    static var description = IntentDescription("Bricht den laufenden aiity-Lauf ab.")
    /// Keep it out of Shortcuts and Spotlight — it is a Live Activity control,
    /// not a user-facing shortcut.
    static var isDiscoverable: Bool { false }
    /// Stopping must not yank the user into the app.
    static var openAppWhenRun: Bool { false }

    init() {}

    func perform() async throws -> some IntentResult {
        AgentRunStopRequest.record()
        await MainActor.run {
            NotificationCenter.default.post(name: .aiityAgentStopRequested, object: nil)
        }
        await Self.endRunningActivities()
        return .result()
    }

    /// Ends every agent activity with a "Gestoppt" card.
    ///
    /// Deliberately unconditional: when the app is alive
    /// `AgentLiveActivityController.cancel()` also ends it, and ending an
    /// already-ended activity is a no-op — a benign double-end is far better
    /// than a Lock Screen that keeps claiming the run is going after the user
    /// pressed stop.
    static func endRunningActivities() async {
        for activity in Activity<AgentActivityAttributes>.activities {
            let state = AgentActivityAttributes.ContentState(
                phase: "Gestoppt",
                detail: activity.content.state.detail,
                progress: 0,
                isComplete: true,
                isError: false
            )
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }
}
