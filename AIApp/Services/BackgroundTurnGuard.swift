import Foundation
import UIKit

/// Owns the one `UIApplication` background-task grant that protects an agent
/// turn.
///
/// Two things changed versus the old arrangement, where
/// `AgentLiveActivityController` began the task from `scene .background`:
///
/// 1. **It starts at TURN START, not when the app is backgrounded.** Apple's
///    model is "protect work already in flight"; asking for the grant only
///    once the user has left means the request lands during the busiest moment
///    of a scene transition, and any work between `send()` and that moment is
///    unprotected. A grant taken in the foreground is legal and costs nothing.
/// 2. **The Live Activity controller is no longer a lifecycle manager.** It
///    presents state; this object owns process time. They were tangled, which
///    is why the expiration handler could only update a card.
///
/// There is deliberately NO trick here to extend the window: no silent audio,
/// no background location, no fabricated `UIBackgroundModes`. iOS grants what
/// it grants (often far less than 30 s under thermal or battery pressure); the
/// job of this type is to make sure the app *notices* the end of the grant and
/// leaves the turn in a resumable, honest state.
@MainActor
final class BackgroundTurnGuard {
    static let shared = BackgroundTurnGuard()

    static let taskName = "aiity.agent.turn"

    /// Test seam: unit tests must be able to drive `fireExpirationForTesting()`
    /// without taking a real UIKit assertion out of the test host.
    static var disableSystemTaskForTesting = false

    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var onExpiration: (@MainActor () -> Void)?
    private var pretendActive = false

    private init() {}

    var isActive: Bool { identifier != .invalid || pretendActive }

    /// Begin (or restart) the grant for one turn.
    /// - Parameter handler: run when iOS is about to take the time back. It
    ///   must be short — see `ChatSession.handleBackgroundTimeExpiring()` for
    ///   the ordered sequence it performs.
    func begin(onExpiration handler: @escaping @MainActor () -> Void) {
        end()
        onExpiration = handler
        guard !Self.disableSystemTaskForTesting else {
            pretendActive = true
            return
        }
        identifier = UIApplication.shared.beginBackgroundTask(withName: Self.taskName) { [weak self] in
            // UIKit calls this on the main thread, but that is not expressible
            // statically; the hop is one runloop tick and the handler itself
            // is written to finish well inside the grace period.
            Task { @MainActor in self?.fireExpiration() }
        }
    }

    /// Hand the grant back. Idempotent — the turn's `defer`, `stop()` and the
    /// expiration path all call it, and only the first one does any work.
    func end() {
        onExpiration = nil
        pretendActive = false
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

    #if DEBUG
    /// Drives the exact code path iOS drives when the grant runs out.
    func fireExpirationForTesting() { fireExpiration() }
    #endif

    private func fireExpiration() {
        let handler = onExpiration
        onExpiration = nil
        // Checkpoint → notify → cancel → repair happens first; the grant is
        // handed back only afterwards, which is the whole point of having a
        // handler at all.
        handler?()
        end()
    }
}
