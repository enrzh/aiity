import Foundation
import BackgroundTasks

/// Periodic, unattended work — the only kind of "autonomy" iOS actually grants.
///
/// **What this is not.** There is no continuous background execution on iOS and
/// nothing here pretends otherwise. `BGAppRefreshTask` is a short opportunistic
/// wake-up (seconds, network allowed); `BGProcessingTask` is a longer one the
/// system typically hands out while the device is idle and charging. Both are
/// scheduled entirely at the system's discretion: `earliestBeginDate` is a
/// *floor*, never a promise, and a device that is rarely used may run neither
/// for days. `BackgroundTurnGuard` remains the separate, unrelated mechanism
/// that protects a turn the user actually started.
///
/// **What deliberately does NOT run here** — each exclusion is load-bearing:
///
///  * **No agent turns, ever.** A `PendingTurn` checkpoint is *not* a work
///    queue. Replaying an interrupted turn re-spends the user's own tokens on a
///    request that may already have completed server-side, which is why resume
///    is a user-tapped "Fortsetzen" affordance and nothing else.
///    `TurnRestorePolicy` (stop-beats-resume) is untouched by this file; the
///    background task only ever *reads* the checkpoint, to decide it must keep
///    its hands off the media directory.
///  * **No provider traffic beyond the already-gated suggestion refresh.** The
///    one network call this file can make goes through
///    `ChatSuggestionService.suggestions(for:savedAppCount:)`, i.e. the shipped
///    gate: explicit model + plain API key + toggle + 24 h cache + one attempt
///    per process. There is no second, ungated call path, and an unset model
///    stays unset — nothing here auto-selects one.
///  * **No notification prompts.** Nothing in this file calls
///    `requestAuthorization`; it posts nothing at all. See `AppNotifications`.
///  * **No CloudKit container is opened.** Instantiating a second
///    `ModelContainer` on the live store file just to "warm" sync would put two
///    CloudKit mirroring stacks on one SQLite file for a speculative benefit.
///    The `remote-notification` background mode already lets CloudKit push
///    changes in; that is the supported mechanism and it is left alone.
enum BackgroundTaskID {
    /// Short, network-capable wake-up. MUST match
    /// `BGTaskSchedulerPermittedIdentifiers` in project.yml — an identifier
    /// missing from the plist makes `register` return false and `submit` throw,
    /// both silently at runtime.
    static let refresh = "com.aiity.app.refresh"
    /// Longer, disk-heavy housekeeping (media + temp-export sweep).
    static let maintenance = "com.aiity.app.maintenance"

    static let all = [refresh, maintenance]
}

// MARK: - Pure policy

/// Every decision this feature makes, extracted so it can be tested without a
/// device, a debugger, or `_simulateLaunchForTaskWithIdentifier:`.
enum BackgroundWorkPolicy {
    /// Floor between refresh wake-ups. Deliberately coarser than the suggestion
    /// cache TTL is fine — the cache is what actually throttles the request; a
    /// wake-up that finds a fresh cache does no network work at all.
    static let refreshInterval: TimeInterval = 4 * 60 * 60
    /// Housekeeping is a once-a-day job at most. Sweeping more often costs disk
    /// churn and saves nothing.
    static let maintenanceInterval: TimeInterval = 24 * 60 * 60

    /// The floor for the next occurrence, measured from the last time the task
    /// ACTUALLY RAN — not from now.
    ///
    /// This is the difference between a task that runs and one that never does.
    /// Both requests are re-submitted every time the scene goes to background,
    /// and a naive `now + 24 h` would move the maintenance floor forward on
    /// every single app switch: a user who opens aiity twice a day would
    /// starve it forever. Anchoring on the last run means re-submitting is
    /// idempotent — the floor only moves when work was actually done.
    static func earliestBegin(now: Date, lastRun: Date?, interval: TimeInterval) -> Date {
        // Never run: as early as the system is willing. `earliestBeginDate` is
        // a floor, not a request for "right now" — iOS still picks the moment.
        guard let lastRun else { return now }
        return max(now, lastRun.addingTimeInterval(interval))
    }

    static func refreshRequest(now: Date = .now, lastRun: Date?) -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskID.refresh)
        request.earliestBeginDate = earliestBegin(
            now: now, lastRun: lastRun, interval: refreshInterval
        )
        return request
    }

    static func maintenanceRequest(now: Date = .now, lastRun: Date?) -> BGProcessingTaskRequest {
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskID.maintenance)
        request.earliestBeginDate = earliestBegin(
            now: now, lastRun: lastRun, interval: maintenanceInterval
        )
        // Pure local file work: demanding power or a network would only make the
        // system defer a job that costs neither.
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        return request
    }

    /// Whether a background wake-up should even ask the suggestion service.
    ///
    /// This is a cheap pre-check, NOT a second gate: the authority stays
    /// `ChatSuggestionService.isEligible` (passed in as `eligible`), and the
    /// service re-evaluates it anyway. Its only job is to keep the background
    /// path from touching the Keychain and the network when the answer is
    /// already known.
    static func shouldAttemptSuggestionRefresh(eligible: Bool, hasFreshCache: Bool) -> Bool {
        eligible && !hasFreshCache
    }

    /// Media may only be swept when no turn's state is in play.
    ///
    /// The sweep keeps whatever the persisted archive references. A turn that
    /// was interrupted mid-flight has a checkpoint but its media may not have
    /// been attached to a persisted message yet, so deleting "unreferenced"
    /// files then would blank out the image a resumed turn is about to show.
    /// (`MediaStore.sweep`'s 15-minute grace window is the second net; this is
    /// the first.)
    static func shouldSweepMedia(hasPendingTurn: Bool, turnGuardActive: Bool) -> Bool {
        !hasPendingTurn && !turnGuardActive
    }
}

/// When each task last actually ran. Small enough for UserDefaults, and it has
/// to survive the process being terminated between wake-ups — which is the
/// normal case, not the exception.
enum BackgroundRunLog {
    /// Test seam.
    static var defaults: UserDefaults = .standard

    private static func key(_ identifier: String) -> String { "bgtask.lastRun.\(identifier)" }

    static func lastRun(_ identifier: String) -> Date? {
        defaults.object(forKey: key(identifier)) as? Date
    }

    /// Noted when the handler STARTS, not when the work finishes: a run that
    /// expires or crashes half-way has still consumed its slot, and treating it
    /// as "never ran" would ask the system for another one immediately.
    static func note(_ identifier: String, at date: Date = .now) {
        defaults.set(date, forKey: key(identifier))
    }
}

// MARK: - Seams

/// What the coordinator needs from `BGTaskScheduler`. Exists so scheduling can
/// be asserted in a unit test: the real scheduler refuses to submit anything in
/// a test host and would make every scheduling assertion vacuous.
protocol BackgroundTaskRequesting: AnyObject {
    func submitRequest(_ request: BGTaskRequest) throws
}

extension BGTaskScheduler: BackgroundTaskRequesting {
    func submitRequest(_ request: BGTaskRequest) throws { try submit(request) }
}

/// The two members of `BGTask` this file uses. `BGTask` itself cannot be
/// constructed, so the lifecycle (complete exactly once, expiration cancels)
/// is only testable behind this.
protocol BackgroundTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGTask: BackgroundTaskHandle {}

/// One in-flight background task. Thread-safe on purpose: iOS may call
/// `expirationHandler` from a different queue than the one the work finishes
/// on, and calling `setTaskCompleted` twice is a documented way to get an
/// exception thrown at you.
final class BackgroundJob: @unchecked Sendable {
    private let handle: BackgroundTaskHandle
    private let lock = NSLock()
    private var finished = false
    private var work: Task<Void, Never>?

    init(handle: BackgroundTaskHandle) {
        self.handle = handle
    }

    /// True once `setTaskCompleted` has been called. A task iOS never hears
    /// back from gets the whole app deprioritised, so this is the invariant the
    /// tests actually assert.
    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    func attach(_ task: Task<Void, Never>) {
        lock.lock(); work = task; lock.unlock()
    }

    /// iOS is taking the time back: stop promptly and report failure, so the
    /// scheduler knows the work did not get done.
    func expire() {
        lock.lock(); let running = work; lock.unlock()
        running?.cancel()
        complete(success: false)
    }

    func complete(success: Bool) {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        handle.expirationHandler = nil
        handle.setTaskCompleted(success: success)
    }
}

/// What a media sweep decided to do. Returned rather than logged so the two
/// refusals — both of which protect user data — are assertable.
enum MediaSweepOutcome: Equatable {
    /// A turn is checkpointed or still holds the foreground grant.
    case skippedTurnInFlight
    /// The chat archive is missing or would not decode.
    case skippedUnreadableArchive
    case swept(keeping: Int)
}

// MARK: - Coordinator

@MainActor
final class BackgroundWorkCoordinator {
    static let shared = BackgroundWorkCoordinator()

    /// Swapped in tests; production submits to the real scheduler.
    var scheduler: BackgroundTaskRequesting = BGTaskScheduler.shared

    private var registered = false

    private init() {}

    // MARK: Registration

    /// Must run before the app finishes launching — that is a hard
    /// `BGTaskScheduler` requirement, hence the call from `AIAppApp.init`.
    /// Registering the same identifier twice traps, so this is idempotent.
    func registerHandlers() {
        guard !registered else { return }
        registered = true
        register(BackgroundTaskID.refresh) { [weak self] task in
            self?.handleRefresh(task)
        }
        register(BackgroundTaskID.maintenance) { [weak self] task in
            self?.handleMaintenance(task)
        }
    }

    private func register(_ identifier: String, handler: @escaping @MainActor (BGTask) -> Void) {
        // `.main`: the launch and expiration callbacks then arrive on the main
        // queue, which is where the work (session state, UserDefaults, the
        // suggestion service) belongs anyway. With `using: nil` both would land
        // on a private queue and every hop would eat into a budget measured in
        // seconds.
        // The Bool result only repeats what the plist already decides (an
        // identifier missing from BGTaskSchedulerPermittedIdentifiers), and a
        // unit test pins that list against BackgroundTaskID.
        _ = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: .main
        ) { task in
            MainActor.assumeIsolated { handler(task) }
        }
    }

    // MARK: Scheduling

    /// Ask for the next occurrence of both tasks. Called at launch and every
    /// time the scene goes to background — submitting an identifier that is
    /// already pending simply replaces it, so this is safe to call often.
    func scheduleAll(now: Date = .now) {
        submit(BackgroundWorkPolicy.refreshRequest(
            now: now, lastRun: BackgroundRunLog.lastRun(BackgroundTaskID.refresh)
        ))
        submit(BackgroundWorkPolicy.maintenanceRequest(
            now: now, lastRun: BackgroundRunLog.lastRun(BackgroundTaskID.maintenance)
        ))
    }

    private func submit(_ request: BGTaskRequest) {
        do {
            try scheduler.submitRequest(request)
        } catch {
            // Simulators, "Background App Refresh" switched off in Settings and
            // Low Power Mode all land here. Nothing to tell the user: this
            // feature is invisible garnish, and the app works identically
            // without it.
            DiagnosticsRecorder.shared.record(
                "bgtask", "submit \(request.identifier) failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: Handlers

    func handleRefresh(_ task: BackgroundTaskHandle) {
        // Note the run and reschedule FIRST. A handler that returns early — or
        // throws its way out — must still have asked for the next occurrence,
        // otherwise the feature silently stops after one run.
        BackgroundRunLog.note(BackgroundTaskID.refresh)
        scheduleAll()
        run(task) { [weak self] in
            _ = await self?.refreshSuggestions()
        }
    }

    func handleMaintenance(_ task: BackgroundTaskHandle) {
        BackgroundRunLog.note(BackgroundTaskID.maintenance)
        scheduleAll()
        run(task) { [weak self] in
            _ = self?.sweepMedia()
            guard !Task.isCancelled else { return }
            _ = TemporaryExportSweeper.prune()
        }
    }

    /// The lifecycle every handler shares: run the work, honour expiration by
    /// cancelling promptly, and call `setTaskCompleted` exactly once on every
    /// path.
    @discardableResult
    func run(_ task: BackgroundTaskHandle, work: @escaping @MainActor () async -> Void) -> BackgroundJob {
        let job = BackgroundJob(handle: task)
        task.expirationHandler = { job.expire() }
        let running = Task { @MainActor in
            await work()
            job.complete(success: !Task.isCancelled)
        }
        job.attach(running)
        return job
    }

    // MARK: Work

    /// Warm the empty-state suggestion cache so the next launch has ideas ready.
    ///
    /// Everything that decides whether a request happens lives in
    /// `ChatSuggestionService` and is NOT duplicated here: an unset model, an
    /// OAuth-only account, a local runtime, the toggle being off, a fresh cache
    /// or an attempt already spent in this process each end the call before any
    /// socket is opened. The saved-app count comes from the tiny
    /// `MiniAppIndex` snapshot rather than the SwiftData store — no container is
    /// opened in the background — and is bucketed inside the service, so still
    /// no user content leaves the device.
    @discardableResult
    func refreshSuggestions(
        settings: ProviderSettings = ProviderSettings.load(),
        savedAppCount: Int = MiniAppIndex.load().count
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let eligible = ChatSuggestionService.isEligible(
            settings: settings,
            credential: ChatSuggestionService.credentialKind(for: settings),
            enabled: AppPreferences.smartSuggestionsEnabled
        )
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cached = ChatSuggestionService.cached(presetId: settings.presetId, model: model) != nil
        guard BackgroundWorkPolicy.shouldAttemptSuggestionRefresh(
            eligible: eligible, hasFreshCache: cached
        ) else { return false }
        _ = await ChatSuggestionService.suggestions(
            for: settings, savedAppCount: savedAppCount
        )
        return true
    }

    /// Delete generated images and video pointers no message references any
    /// more. Each image is commonly 1–4 MB, so this is the one piece of
    /// housekeeping that measurably gives storage back.
    @discardableResult
    func sweepMedia() -> MediaSweepOutcome {
        guard BackgroundWorkPolicy.shouldSweepMedia(
            hasPendingTurn: PendingTurnStore.load() != nil,
            turnGuardActive: BackgroundTurnGuard.shared.isActive
        ) else { return .skippedTurnInFlight }
        // nil means the archive is missing or would not decode — and an empty
        // "referenced" set would delete every image the user has. Refusing to
        // sweep is the only safe reading.
        guard let referenced = ChatSession.persistedMediaIds() else {
            return .skippedUnreadableArchive
        }
        MediaStore.sweep(keeping: referenced)
        return .swept(keeping: referenced.count)
    }
}

// MARK: - Temp exports

/// Removes the share-sheet exports the app leaves in `tmp`.
///
/// Backups, diagnostics reports and mini-app downloads are written there for
/// `ShareLink` to hand to Mail/Files/AirDrop and are then simply abandoned; a
/// library backup can be several MB. iOS purges `tmp` only under pressure and
/// on its own schedule.
///
/// Strictly opt-in by name: `tmp` is shared with URLSession and other system
/// machinery, so this never enumerates-and-deletes wholesale, only files this
/// app is known to have written, and only once they are a day old (a share
/// sheet may still be holding a fresh one).
enum TemporaryExportSweeper {
    /// Test seam.
    static var directoryOverride: URL?

    static let maxAge: TimeInterval = 24 * 60 * 60

    /// Prefix match against the last path component. `aiity-backup.json` is a
    /// fixed name, the diagnostics report carries a timestamp, and mini-app
    /// downloads land in a `miniapp-downloads` directory.
    static let ownedPrefixes = ["aiity-backup", "aiity-diagnose-", "miniapp-downloads"]

    static func isOwned(_ name: String) -> Bool {
        ownedPrefixes.contains { name.hasPrefix($0) }
    }

    private static var directory: URL {
        directoryOverride ?? FileManager.default.temporaryDirectory
    }

    @discardableResult
    static func prune(olderThan age: TimeInterval = maxAge, now: Date = .now) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        let cutoff = now.addingTimeInterval(-age)
        var removed = 0
        for entry in entries where isOwned(entry.lastPathComponent) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified <= cutoff else { continue }
            do {
                try fm.removeItem(at: entry)
                removed += 1
            } catch {
                continue   // still open in a share sheet, or already gone
            }
        }
        return removed
    }
}
