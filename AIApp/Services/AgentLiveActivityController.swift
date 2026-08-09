import Foundation
import ActivityKit
import UIKit
import UserNotifications

/// Starts / updates / ends the agent Live Activity.
///
/// It used to double as the app's background-lifecycle manager (it owned the
/// `beginBackgroundTask` grant and began it from `scene .background`). That
/// belongs to `BackgroundTurnGuard` now, which takes the grant at TURN START;
/// this type is presentation again, and calls `BackgroundTurnGuard.shared.end()`
/// at the three points where a turn is definitively over.
@MainActor
final class AgentLiveActivityController {
    static let shared = AgentLiveActivityController()

    private var activity: Activity<AgentActivityAttributes>?
    /// Read by the interruption policy: a stream that died while the app was
    /// backgrounded is a suspension, not a network fault.
    private(set) var wasBackgrounded = false
    private var lastPrompt = ""
    /// True while a chat/build turn is in flight (for screen-wake preference).
    private(set) var isAgentBusy = false

    private init() {}

    /// How long the system should keep presenting the activity before treating
    /// it as stale. The old 120s/90s were shorter than the work: a group round
    /// is minutes, and three auto rounds far more — so the activity went stale
    /// mid-run and stopped showing, which looks exactly like it never started.
    /// Every update pushes the window out again, so it stays live while the
    /// agent is actually working.
    private static let staleWindow: TimeInterval = 15 * 60

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Lifecycle

    func start(prompt: String) {
        lastPrompt = prompt
        wasBackgrounded = false
        backgroundedDuringTurn = false
        isAgentBusy = true
        ScreenWake.shared.setAgentBusy(true)

        // The user just kicked off an agent turn while the app is active — the
        // one contextual moment to secure delivery for "Antwort fertig".
        // `.provisional` shows NO dialog: the first completion arrives quietly
        // in the notification centre and iOS itself offers keep/turn-off, so
        // the decision stays with the user. Crucially, notifyDone — which only
        // ever runs from the background — then never has to request
        // authorization (the system cannot present the dialog back there; the
        // old code lost the first notification and queued a context-free
        // prompt for later). Fire-and-forget so the turn is never delayed.
        Task {
            if await AppNotifications.gate() == .ask {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .provisional])
            }
        }

        guard #available(iOS 16.2, *) else { return }
        guard isSupported else {
            // Silently returning here is why "no Live Activity" was
            // indistinguishable from a bug: the user can switch them off per
            // app in Settings → aiity → Live-Aktivitäten, and nothing said so.
            #if DEBUG
            print("AIITY-LA disabled: Live Activities are off for this app (Settings → aiity)")
            #endif
            return
        }
        #if DEBUG
        print("AIITY-LA start")
        #endif
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
                content: .init(state: state, staleDate: Date().addingTimeInterval(Self.staleWindow)),
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
                ActivityContent(state: next, staleDate: Date().addingTimeInterval(Self.staleWindow))
            )
        }
    }

    func complete(summary: String = String(localized: "Fertig")) {
        finishBusyState()
        BackgroundTurnGuard.shared.end()
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
            notifyDone(title: String(localized: "Antwort fertig"), body: summary)
        }
        wasBackgrounded = false
    }

    func fail(message: String) {
        finishBusyState()
        BackgroundTurnGuard.shared.end()
        guard #available(iOS 16.2, *) else {
            if wasBackgrounded { notifyDone(title: String(localized: "Fehler"), body: message) }
            activity = nil
            return
        }
        if let activity {
            let state = AgentActivityAttributes.ContentState(
                phase: String(localized: "Fehler"),
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
        BackgroundTurnGuard.shared.end()
        guard #available(iOS 16.2, *), let activity else {
            self.activity = nil
            return
        }
        let state = AgentActivityAttributes.ContentState(
            phase: String(localized: "Gestoppt"),
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

    /// How long the "Pausiert" card stays fresh. Deliberately SHORT.
    ///
    /// The 15-minute `staleWindow` is right for a run that is actually running
    /// — every update pushes it out again. It is exactly wrong once the
    /// process has been suspended: nothing pushes it any more, so the Lock
    /// Screen kept advertising "Läuft im Hintergrund…" for up to a quarter of
    /// an hour after the work had frozen. That frozen card IS the reported
    /// "it silently stopped" symptom. A paused activity therefore says so, and
    /// goes stale in a minute if the user does not open the app.
    private static let pausedStaleWindow: TimeInterval = 60

    /// Call when the app enters background while the agent is busy.
    ///
    /// No longer begins a background task — `BackgroundTurnGuard` already took
    /// the grant when the turn started, which is both earlier and the right
    /// owner.
    func enterBackgroundWhileBusy() {
        wasBackgrounded = true
        backgroundedDuringTurn = true
        update(phase: String(localized: "Läuft im Hintergrund…"), progress: nil)
    }

    /// Whether THIS turn was ever backgrounded. Unlike `wasBackgrounded` it is
    /// only reset by `start()`, so it survives the foreground transition — and
    /// it has to: the frozen socket throws its `URLError` *after* the user has
    /// come back, and by then `wasBackgrounded` is already false again. Reading
    /// the wrong one is what made a suspension look like a network outage.
    private(set) var backgroundedDuringTurn = false

    /// The background grant ran out. Say so instead of freezing on
    /// "Läuft im Hintergrund…". Keeps `isComplete == false`, so the Stop
    /// button still renders on the paused card — stopping there is what
    /// discards the resume checkpoint.
    func markPausedForExpiredBackgroundTime() {
        finishBusyState()
        guard #available(iOS 16.2, *), let activity else { return }
        let current = activity.content.state
        let state = AgentActivityAttributes.ContentState(
            phase: String(localized: "Pausiert — App öffnen"),
            detail: String(lastPrompt.prefix(60)),
            progress: current.progress,
            isComplete: false,
            isError: false
        )
        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.pausedStaleWindow))
            )
        }
    }

    /// Call when returning to foreground.
    func enterForeground() {
        // Keep wasBackgrounded until complete so notification still fires if needed —
        // only clear the flag if still busy (user is watching again).
        if activity != nil {
            wasBackgrounded = false
        }
        // The background grant is owned by BackgroundTurnGuard and released by
        // the turn's defer / stop() / complete() — never here.
    }

    private func bump(_ p: Double) -> Double {
        min(0.92, p + 0.04)
    }

    private func notifyDone(title: String, body: String) {
        Task {
            // Every caller is a wasBackgrounded path, i.e. the app is in the
            // BACKGROUND: never requestAuthorization here (the system cannot
            // present the first-time dialog, the notification would be lost
            // and the prompt would surface later without context). Post only
            // when the user — or the provisional grant from start() — already
            // allows it.
            guard await AppNotifications.gate() == .post else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "aiity-agent-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(req)
        }
    }
}
