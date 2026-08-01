import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One place that knows the app is running out of memory, so the parts that can
/// give some back hear about it.
///
/// iOS sends a memory warning and then, if the footprint keeps climbing, kills
/// the process without a second notice. A real device report showed five
/// warnings arriving in the last eight seconds of a run that ended in a jetsam
/// kill — the app had every chance to react and reacted to none of them.
///
/// Deliberately its own type rather than a `MLXRuntime` detail: the runtime is
/// the biggest consumer, but "we are about to be killed" is not an MLX fact,
/// and an in-flight agent round wants to know too.
final class MemoryPressure: @unchecked Sendable {
    static let shared = MemoryPressure()

    private let lock = NSLock()
    private var warnings = 0
    /// Bounded: only recent ones matter, and this is consulted from a hot path.
    private var timestamps: [Date] = []
    private static let maxTimestamps = 64
    private var handlers: [(String, () -> Void)] = []
    private var observer: NSObjectProtocol?

    /// Begin listening. Safe to call more than once.
    func start() {
        #if canImport(UIKit)
        lock.lock()
        let alreadyStarted = observer != nil
        lock.unlock()
        guard !alreadyStarted else { return }

        let token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.note()
        }
        lock.lock()
        observer = token
        lock.unlock()
        #endif
    }

    /// Register something to release memory. Called on every warning, on
    /// whichever thread the warning arrives on — keep it fast and non-blocking.
    func onPressure(_ name: String, _ handler: @escaping () -> Void) {
        lock.lock()
        handlers.removeAll { $0.0 == name }   // re-registering replaces
        handlers.append((name, handler))
        lock.unlock()
    }

    /// The warning path, exposed so it can be exercised without a device.
    func note() {
        lock.lock()
        warnings += 1
        timestamps.append(Date())
        if timestamps.count > Self.maxTimestamps {
            timestamps.removeFirst(timestamps.count - Self.maxTimestamps)
        }
        let toRun = handlers
        lock.unlock()

        DiagnosticsRecorder.shared.record(
            "speicher", "Speicherdruck — gebe \(toRun.count) Puffer frei"
        )
        for (_, handler) in toRun { handler() }
    }

    var warningCount: Int {
        lock.lock(); defer { lock.unlock() }
        return warnings
    }

    /// How many warnings have arrived since `date`.
    ///
    /// Note what this is NOT for: a single warning is not a reason to stop
    /// doing anything. On device, a healthy three-agent round on a local model
    /// produced six warnings and finished fine — each one was absorbed by
    /// releasing the model. Treating one warning as "we are about to die"
    /// would abort nearly every local round and trade a crash for a broken
    /// feature. Only a count far above that is evidence of a runaway.
    func warnings(since date: Date) -> Int {
        lock.lock(); defer { lock.unlock() }
        return timestamps.filter { $0 >= date }.count
    }

    /// Test seam.
    func reset() {
        lock.lock()
        warnings = 0
        timestamps.removeAll()
        handlers.removeAll()
        lock.unlock()
    }
}
