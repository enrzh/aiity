import AppIntents
import Foundation

/// The persisted "the user asked for a new conversation" request.
///
/// Same indirection as `AgentRunStopRequest`, for the same reason: the intent
/// that records it may be compiled into both binaries and must not reference a
/// single app-only type (`IntentRouter`, `ChatSession`, SwiftData). It writes
/// the request down; the app decides what a new conversation means.
///
/// The App Group container rather than `UserDefaults.standard`: a plain
/// `AppIntent` carries no promise about which process runs `perform()` — with
/// `openAppWhenRun` it is the app, but a future in-widget call site would write
/// into the extension's own defaults and the request would silently vanish.
enum NewChatRequest {
    static let defaultsKey = "aiity.newChatRequestedAt"

    /// Test seam only. Production always uses the shared App Group.
    static var store: UserDefaults? = UserDefaults(suiteName: PinnedMiniAppStore.appGroupID)

    static func record(at date: Date = Date()) {
        store?.set(date.timeIntervalSince1970, forKey: defaultsKey)
    }

    /// Consume a fresh request — true exactly once per tap. Only the APP may
    /// call this.
    ///
    /// `maxAge` exists because the flag outlives the process: without it, a tap
    /// on a control while the phone stays locked would still yank the user into
    /// a brand-new conversation hours later, on the next unrelated launch.
    static func consume(maxAge: TimeInterval = 120, now: Date = Date()) -> Bool {
        guard let raw = store?.double(forKey: defaultsKey), raw > 0 else { return false }
        store?.removeObject(forKey: defaultsKey)
        return now.timeIntervalSince1970 - raw <= maxAge
    }
}

extension Notification.Name {
    /// Posted in the app process by `NewChatIntent`. The app observes it so a
    /// tap on an already-running app opens the new conversation immediately
    /// instead of waiting for the next foreground transition.
    static let aiityNewChatRequested = Notification.Name("aiity.chat.newRequested")
}

/// "Neuer Chat" — the Control Center / Lock Screen / Action-button control, and
/// a plain Shortcuts action.
///
/// `openAppWhenRun` is the whole mechanism: a control cannot open a URL by
/// itself, `OpenURLIntent` only accepts universal links (a custom scheme like
/// `aiity://chat` is rejected), and `UIApplication.open` does not exist in an
/// extension. So the intent asks the system to foreground the app and leaves a
/// request behind for it — see `NewChatRequest`.
///
/// This is why it must be a member of BOTH targets (project.yml), exactly like
/// `StopAgentRunIntent`: with `openAppWhenRun` the system performs the intent
/// in the APP process, and an intent the app binary does not contain never runs
/// at all.
struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Neuer Chat"
    static var description = IntentDescription("Öffnet aiity mit einer neuen Unterhaltung.")
    static var openAppWhenRun: Bool { true }

    init() {}

    func perform() async throws -> some IntentResult {
        NewChatRequest.record()
        await MainActor.run {
            NotificationCenter.default.post(name: .aiityNewChatRequested, object: nil)
        }
        return .result()
    }
}
