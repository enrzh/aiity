import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Exactly what the user is being asked to allow — the concrete payload, never
/// a paraphrase of it. "Termin anlegen?" with the title, the day, the time and
/// the calendar underneath; not "Der Agent möchte deinen Kalender ändern".
struct ToolConfirmationRequest: Equatable {
    var title: String
    /// One line per field, already formatted for a human.
    var lines: [String]
    var confirmTitle: String
    var isDestructive: Bool = false

    var message: String { lines.joined(separator: "\n") }
}

/// The gate every write goes through.
///
/// Async and injectable for one reason: a test must be able to prove that a
/// write CANNOT happen when this returns false — not that it usually doesn't.
protocol ToolConfirming: AnyObject {
    func confirm(_ request: ToolConfirmationRequest) async -> Bool
}

/// The production gate: a native alert on the topmost view controller, the same
/// shape `MiniAppRunnerView.confirmOpenExternal` uses for leaving the app.
///
/// Fails CLOSED, in both directions that matter:
///  * no foreground-active app → `false`. A turn keeps running for a while
///    after the user leaves (`BackgroundTurnGuard`), and a write that slipped
///    through there would be exactly the silent modification this whole
///    feature is built to prevent. It also means no system-looking dialog can
///    be conjured up while the user is somewhere else.
///  * no presenter → `false`.
final class SystemToolConfirmer: ToolConfirming {
    static let shared = SystemToolConfirmer()

    func confirm(_ request: ToolConfirmationRequest) async -> Bool {
        #if canImport(UIKit)
        return await present(request)
        #else
        return false
        #endif
    }

    #if canImport(UIKit)
    @MainActor
    private func present(_ request: ToolConfirmationRequest) async -> Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        guard let presenter = Self.topViewController() else { return false }
        return await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ value: Bool) {
                if !resumed { resumed = true; continuation.resume(returning: value) }
            }
            let alert = UIAlertController(
                title: request.title,
                message: request.message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "Abbrechen"), style: .cancel) { _ in
                finish(false)
            })
            alert.addAction(UIAlertAction(
                title: request.confirmTitle,
                style: request.isDestructive ? .destructive : .default
            ) { _ in finish(true) })
            presenter.present(alert, animated: true)
        }
    }

    @MainActor
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let root = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
            ?? scene?.windows.first?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
    #endif
}

/// Used wherever a confirmer is structurally required but none can exist.
/// Denies everything, silently — a missing UI must never mean "yes".
final class DenyingToolConfirmer: ToolConfirming {
    func confirm(_ request: ToolConfirmationRequest) async -> Bool { false }
}

/// Per-turn failure budget, shared by the device-data tools of ONE turn.
///
/// Same lesson as `ImageGenerationTool.Attempts`: a permission the user just
/// declined will be declined again, and a model that keeps trying burns the
/// whole tool budget rediscovering it — here with a modal alert popping up
/// each time, which is far worse than a wasted HTTP round trip.
final class ToolAttemptLatch {
    static let maxFailuresPerTool = 2

    private var counts: [String: Int] = [:]

    func record(_ tool: String) {
        counts[tool, default: 0] += 1
    }

    func isExhausted(_ tool: String) -> Bool {
        (counts[tool] ?? 0) >= Self.maxFailuresPerTool
    }

    /// A declined confirmation exhausts the budget immediately: the user said
    /// no once, which is an answer, not a transient failure.
    func exhaust(_ tool: String) {
        counts[tool] = Self.maxFailuresPerTool
    }
}
