import Foundation
import ActivityKit
import UIKit
import UserNotifications

/// Starts / updates / ends the agent Live Activity and coordinates a
/// background task so streaming can finish after the user leaves the app.
@MainActor
final class AgentLiveActivityController {
    static let shared = AgentLiveActivityController()

    private var activity: Activity<AgentActivityAttributes>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var wasBackgrounded = false
    private var lastPrompt = ""
    /// True while a chat/build turn is in flight (for screen-wake preference).
    private(set) var isAgentBusy = false

    private init() {}

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Lifecycle

    func start(prompt: String) {
        lastPrompt = prompt
        wasBackgrounded = false
        isAgentBusy = true
        ScreenWake.shared.setAgentBusy(true)

        guard #available(iOS 16.2, *), isSupported else { return }
        // End any stale activity from a previous crash/suspend.
        for existing in Activity<AgentActivityAttributes>.activities {
            Task { await existing.end(nil, dismissalPolicy: .immediate) }
        }

        let preview = String(prompt.prefix(80))
        let attributes = AgentActivityAttributes(promptPreview: preview, startedAt: .now)
        let state = AgentActivityAttributes.ContentState(
            phase: "Denkt nach…",
            detail: preview,
            progress: 0.08,
            isComplete: false,
            isError: false
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Date().addingTimeInterval(120)),
                pushType: nil
            )
        } catch {
            activity = nil
            #if DEBUG
            print("Live Activity start failed: \(error)")
            #endif
        }
    }

    func update(phase: String?, detail: String? = nil, progress: Double? = nil) {
        guard #available(iOS 16.2, *), let activity else { return }
        let current = activity.content.state
        let next = AgentActivityAttributes.ContentState(
            phase: phase ?? current.phase,
            detail: detail ?? current.detail,
            progress: min(0.95, progress ?? bump(current.progress)),
            isComplete: false,
            isError: false
        )
        Task {
            await activity.update(
                ActivityContent(state: next, staleDate: Date().addingTimeInterval(90))
            )
        }
    }

    func complete(summary: String = "Fertig") {
        finishBusyState()
        endBackgroundTask()
        guard #available(iOS 16.2, *) else {
            if wasBackgrounded { notifyDone(title: "aiity", body: summary) }
            activity = nil
            return
        }
        if let activity {
            let state = AgentActivityAttributes.ContentState(
                phase: summary,
                detail: String(lastPrompt.prefix(60)),
                progress: 1,
                isComplete: true,
                isError: false
            )
            Task {
                await activity.end(
                    ActivityContent(state: state, staleDate: nil),
                    dismissalPolicy: .after(.now.addingTimeInterval(8))
                )
            }
        }
        activity = nil
        if wasBackgrounded {
            notifyDone(title: "Antwort fertig", body: summary)
        }
        wasBackgrounded = false
    }

    func fail(message: String) {
        finishBusyState()
        endBackgroundTask()
        guard #available(iOS 16.2, *) else {
            if wasBackgrounded { notifyDone(title: "Fehler", body: message) }
            activity = nil
            return
        }
        if let activity {
            let state = AgentActivityAttributes.ContentState(
                phase: "Fehler",
                detail: String(message.prefix(100)),
                progress: 1,
                isComplete: true,
                isError: true
            )
            Task {
                await activity.end(
                    ActivityContent(state: state, staleDate: nil),
                    dismissalPolicy: .after(.now.addingTimeInterval(12))
                )
            }
        }
        activity = nil
        if wasBackgrounded {
            // Title = short reason, not generic “aiity Fehler”
            let short = String(message.prefix(48))
            notifyDone(title: short, body: message)
        }
        wasBackgrounded = false
    }

    func cancel() {
        finishBusyState()
        endBackgroundTask()
        guard #available(iOS 16.2, *), let activity else {
            self.activity = nil
            return
        }
        let state = AgentActivityAttributes.ContentState(
            phase: "Gestoppt",
            detail: String(lastPrompt.prefix(60)),
            progress: 0,
            isComplete: true,
            isError: false
        )
        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
        self.activity = nil
        wasBackgrounded = false
    }

    private func finishBusyState() {
        isAgentBusy = false
        ScreenWake.shared.setAgentBusy(false)
    }

    // MARK: - Background

    /// Call when the app enters background while the agent is busy.
    func enterBackgroundWhileBusy() {
        wasBackgrounded = true
        beginBackgroundTask()
        update(phase: "Läuft im Hintergrund…", progress: nil)
    }

    /// Call when returning to foreground.
    func enterForeground() {
        // Keep wasBackgrounded until complete so notification still fires if needed —
        // only clear the flag if still busy (user is watching again).
        if activity != nil {
            wasBackgrounded = false
        }
        // Don't end background task here if still busy — let complete() end it.
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "aiity.agent") { [weak self] in
            Task { @MainActor in
                self?.update(phase: "Hintergrundzeit fast abgelaufen — App öffnen", progress: 0.9)
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func bump(_ p: Double) -> Double {
        min(0.92, p + 0.04)
    }

    private func notifyDone(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "aiity-agent-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(req)
        }
    }
}
