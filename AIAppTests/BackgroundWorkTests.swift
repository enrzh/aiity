import XCTest
import BackgroundTasks
@testable import AIApp

// BGTaskScheduler cannot be driven from a test: a real launch only happens at
// the system's discretion, and the debugger-only
// `_simulateLaunchForTaskWithIdentifier:` is not reachable from xcodebuild. So
// what is pinned here is everything on THIS side of that boundary — the
// identifiers the plist permits, the requests submitted, the completion
// contract (exactly once, on every path, including expiration), and the promise
// that the background wake-up cannot spend a token the gate would have refused.

// MARK: - Test doubles

private final class FakeScheduler: BackgroundTaskRequesting {
    var submitted: [BGTaskRequest] = []
    var errorToThrow: Error?

    struct Refused: Error {}

    func submitRequest(_ request: BGTaskRequest) throws {
        if let errorToThrow { throw errorToThrow }
        submitted.append(request)
    }

    func request(_ identifier: String) -> BGTaskRequest? {
        submitted.first { $0.identifier == identifier }
    }
}

private final class FakeTask: BackgroundTaskHandle, @unchecked Sendable {
    var expirationHandler: (() -> Void)?
    private(set) var completions: [Bool] = []

    func setTaskCompleted(success: Bool) { completions.append(success) }

    func expire() { expirationHandler?() }
}

/// Counts every request that reaches URLSession and lets none of them out.
/// Same shape as the App Intents tests use for "a Shortcut never spends tokens".
private final class RequestCounter: URLProtocol {
    nonisolated(unsafe) static var count = 0
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        count += 1
        lock.unlock()
        return false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

// MARK: - Identifiers and Info.plist

final class BackgroundTaskIdentifierTests: XCTestCase {

    /// An identifier the app registers but the plist does not permit fails
    /// twice over — `register` returns false, `submit` throws — and both are
    /// silent at runtime. This is the only place the two lists are compared.
    func testEveryIdentifierIsPermittedByTheInfoPlist() throws {
        let permitted = Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
        ) as? [String]
        let declared = try XCTUnwrap(permitted, "BGTaskSchedulerPermittedIdentifiers is missing")
        XCTAssertEqual(Set(declared), Set(BackgroundTaskID.all))
    }

    /// BGAppRefreshTask needs `fetch`, BGProcessingTask needs `processing`, and
    /// CloudKit's silent pushes still need `remote-notification` — the modes
    /// are additive, and dropping the last one would quietly stop sync between
    /// launches.
    func testTheBackgroundModesCoverBothTaskTypesAndStillCloudKit() throws {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        let declared = Set(try XCTUnwrap(modes))
        XCTAssertTrue(declared.contains("fetch"))
        XCTAssertTrue(declared.contains("processing"))
        XCTAssertTrue(declared.contains("remote-notification"))
    }

    func testIdentifiersAreReverseDNSUnderTheBundleId() {
        for identifier in BackgroundTaskID.all {
            XCTAssertTrue(identifier.hasPrefix("com.aiity.app."), identifier)
        }
        XCTAssertEqual(Set(BackgroundTaskID.all).count, BackgroundTaskID.all.count)
    }
}

// MARK: - Request shape

final class BackgroundWorkPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testTheRefreshRequestAsksForTheRightIdentifierAndFloor() {
        let lastRun = now.addingTimeInterval(-60)
        let request = BackgroundWorkPolicy.refreshRequest(now: now, lastRun: lastRun)
        XCTAssertEqual(request.identifier, BackgroundTaskID.refresh)
        XCTAssertEqual(
            request.earliestBeginDate,
            lastRun.addingTimeInterval(BackgroundWorkPolicy.refreshInterval)
        )
    }

    /// Housekeeping is local file work: requiring power or a network would only
    /// make the system defer a job that needs neither.
    func testTheMaintenanceRequestNeedsNeitherPowerNorNetwork() {
        let request = BackgroundWorkPolicy.maintenanceRequest(now: now, lastRun: nil)
        XCTAssertEqual(request.identifier, BackgroundTaskID.maintenance)
        XCTAssertFalse(request.requiresExternalPower)
        XCTAssertFalse(request.requiresNetworkConnectivity)
    }

    /// THE scheduling bug this anchoring exists to prevent: both requests are
    /// re-submitted every time the scene goes to background, so a floor of
    /// `now + interval` would move forward on every app switch and a user who
    /// opens aiity twice a day would starve the 24 h task forever.
    func testResubmittingDoesNotPushAnOverdueTaskFurtherAway() {
        let lastRun = now.addingTimeInterval(-30 * 24 * 60 * 60)
        XCTAssertEqual(
            BackgroundWorkPolicy.earliestBegin(
                now: now, lastRun: lastRun,
                interval: BackgroundWorkPolicy.maintenanceInterval
            ),
            now, "an overdue task must stay due, not be pushed out again"
        )
    }

    func testATaskThatHasNeverRunIsDueImmediately() {
        XCTAssertEqual(
            BackgroundWorkPolicy.earliestBegin(
                now: now, lastRun: nil, interval: BackgroundWorkPolicy.refreshInterval
            ),
            now
        )
    }

    func testARecentRunPushesTheFloorOneFullIntervalPastThatRun() {
        let lastRun = now.addingTimeInterval(-3600)
        XCTAssertEqual(
            BackgroundWorkPolicy.earliestBegin(
                now: now, lastRun: lastRun, interval: BackgroundWorkPolicy.refreshInterval
            ),
            lastRun.addingTimeInterval(BackgroundWorkPolicy.refreshInterval)
        )
    }

    func testABackgroundRefreshIsOnlyAttemptedWhenTheGateSaysYesAndTheCacheIsStale() {
        XCTAssertTrue(BackgroundWorkPolicy.shouldAttemptSuggestionRefresh(
            eligible: true, hasFreshCache: false
        ))
        // The 24 h cache is the real throttle — a wake-up that finds one does
        // no network work at all.
        XCTAssertFalse(BackgroundWorkPolicy.shouldAttemptSuggestionRefresh(
            eligible: true, hasFreshCache: true
        ))
        XCTAssertFalse(BackgroundWorkPolicy.shouldAttemptSuggestionRefresh(
            eligible: false, hasFreshCache: false
        ))
    }

    /// Media belonging to an interrupted turn is not attached to a persisted
    /// message yet — sweeping then would blank out the image a resumed turn is
    /// about to show.
    func testMediaIsNeverSweptWhileATurnIsInPlay() {
        XCTAssertTrue(BackgroundWorkPolicy.shouldSweepMedia(
            hasPendingTurn: false, turnGuardActive: false
        ))
        XCTAssertFalse(BackgroundWorkPolicy.shouldSweepMedia(
            hasPendingTurn: true, turnGuardActive: false
        ))
        XCTAssertFalse(BackgroundWorkPolicy.shouldSweepMedia(
            hasPendingTurn: false, turnGuardActive: true
        ))
    }
}

// MARK: - Scheduling

@MainActor
final class BackgroundSchedulingTests: XCTestCase {
    private var scheduler: FakeScheduler!
    private var previousToggle: Any?
    private var suite: UserDefaults!
    private let suiteName = "aiity.tests.bgtask.runlog"

    override func setUp() {
        super.setUp()
        scheduler = FakeScheduler()
        BackgroundWorkCoordinator.shared.scheduler = scheduler
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        BackgroundRunLog.defaults = suite
        // These tests drive the real handlers, so close the suggestion gate:
        // whatever provider the host container happens to have configured must
        // not turn a scheduling assertion into a live provider call.
        previousToggle = UserDefaults.standard.object(forKey: AppPreferences.smartSuggestionsKey)
        UserDefaults.standard.set(false, forKey: AppPreferences.smartSuggestionsKey)
    }

    override func tearDown() {
        if let previousToggle {
            UserDefaults.standard.set(previousToggle, forKey: AppPreferences.smartSuggestionsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppPreferences.smartSuggestionsKey)
        }
        BackgroundRunLog.defaults = .standard
        suite.removePersistentDomain(forName: suiteName)
        BackgroundWorkCoordinator.shared.scheduler = BGTaskScheduler.shared
        super.tearDown()
    }

    func testSchedulingSubmitsBothTasks() {
        BackgroundWorkCoordinator.shared.scheduleAll()
        XCTAssertEqual(
            Set(scheduler.submitted.map(\.identifier)), Set(BackgroundTaskID.all)
        )
        XCTAssertTrue(scheduler.request(BackgroundTaskID.refresh) is BGAppRefreshTaskRequest)
        XCTAssertTrue(scheduler.request(BackgroundTaskID.maintenance) is BGProcessingTaskRequest)
    }

    /// Background App Refresh switched off in Settings, Low Power Mode and the
    /// simulator all make `submit` throw. The app must shrug.
    func testASchedulerThatRefusesIsNotAnError() {
        scheduler.errorToThrow = FakeScheduler.Refused()
        BackgroundWorkCoordinator.shared.scheduleAll()
        XCTAssertTrue(scheduler.submitted.isEmpty)
    }

    /// A handler that does not re-arm makes the feature run exactly once, ever.
    /// Both handlers therefore reschedule before they do any work.
    func testEachHandlerRearmsTheNextOccurrence() async {
        let refreshTask = FakeTask()
        BackgroundWorkCoordinator.shared.handleRefresh(refreshTask)
        XCTAssertEqual(
            Set(scheduler.submitted.map(\.identifier)), Set(BackgroundTaskID.all)
        )

        // …and the run is recorded, so the NEXT submission is measured from
        // here rather than from whenever the user last closed the app.
        XCTAssertNotNil(BackgroundRunLog.lastRun(BackgroundTaskID.refresh))

        scheduler.submitted.removeAll()
        let maintenanceTask = FakeTask()
        BackgroundWorkCoordinator.shared.handleMaintenance(maintenanceTask)
        XCTAssertEqual(
            Set(scheduler.submitted.map(\.identifier)), Set(BackgroundTaskID.all)
        )
        XCTAssertNotNil(BackgroundRunLog.lastRun(BackgroundTaskID.maintenance))
        await settle()
    }

    /// A task that has never run asks for the earliest floor the system allows;
    /// once it has run, the floor sits a full interval past that run.
    func testTheSubmittedFloorFollowsTheRunLog() {
        BackgroundWorkCoordinator.shared.scheduleAll(now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(
            scheduler.request(BackgroundTaskID.maintenance)?.earliestBeginDate,
            Date(timeIntervalSince1970: 1_000_000)
        )

        scheduler.submitted.removeAll()
        BackgroundRunLog.note(BackgroundTaskID.maintenance, at: Date(timeIntervalSince1970: 1_000_000))
        BackgroundWorkCoordinator.shared.scheduleAll(now: Date(timeIntervalSince1970: 1_000_100))
        XCTAssertEqual(
            scheduler.request(BackgroundTaskID.maintenance)?.earliestBeginDate,
            Date(timeIntervalSince1970: 1_000_000)
                .addingTimeInterval(BackgroundWorkPolicy.maintenanceInterval)
        )
    }

    /// Let the detached work task reach its completion call.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

// MARK: - Lifecycle: completion happens exactly once

@MainActor
final class BackgroundJobLifecycleTests: XCTestCase {

    func testWorkThatFinishesReportsSuccessExactlyOnce() async {
        let task = FakeTask()
        let job = BackgroundWorkCoordinator.shared.run(task) {}
        await waitUntil { job.isFinished }
        XCTAssertEqual(task.completions, [true])
        // The handler is dropped so a late expiration cannot complete twice.
        XCTAssertNil(task.expirationHandler)
    }

    /// iOS taking the time back must cancel the work *and* report failure — a
    /// task the scheduler never hears back from gets the whole app
    /// deprioritised for future wake-ups.
    func testExpirationCancelsTheWorkAndReportsFailure() async {
        let task = FakeTask()
        let started = expectation(description: "work started")
        let job = BackgroundWorkCoordinator.shared.run(task) {
            started.fulfill()
            // Long enough that only cancellation can end it.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        await fulfillment(of: [started], timeout: 2)
        task.expire()
        XCTAssertEqual(task.completions, [false])
        await waitUntil { job.isFinished }
        // The work task really was cancelled, and its own completion call after
        // waking up is swallowed rather than becoming a second setTaskCompleted.
        XCTAssertEqual(task.completions, [false])
    }

    func testACompletedTaskIgnoresALateExpiration() async {
        let task = FakeTask()
        let job = BackgroundWorkCoordinator.shared.run(task) {}
        await waitUntil { job.isFinished }
        task.expirationHandler?()   // nil by then; call defensively anyway
        job.expire()
        XCTAssertEqual(task.completions, [true])
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "condition never became true")
    }
}

// MARK: - The suggestion refresh reuses the shipped gate

@MainActor
final class BackgroundSuggestionRefreshTests: XCTestCase {
    private var scheduler: FakeScheduler!
    private var previousToggle: Any?

    override func setUp() {
        super.setUp()
        scheduler = FakeScheduler()
        BackgroundWorkCoordinator.shared.scheduler = scheduler
        previousToggle = UserDefaults.standard.object(forKey: AppPreferences.smartSuggestionsKey)
        RequestCounter.count = 0
        URLProtocol.registerClass(RequestCounter.self)
        ChatSuggestionService.resetLaunchThrottleForTesting()
    }

    override func tearDown() {
        URLProtocol.unregisterClass(RequestCounter.self)
        if let previousToggle {
            UserDefaults.standard.set(previousToggle, forKey: AppPreferences.smartSuggestionsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppPreferences.smartSuggestionsKey)
        }
        BackgroundWorkCoordinator.shared.scheduler = BGTaskScheduler.shared
        ChatSuggestionService.resetLaunchThrottleForTesting()
        super.tearDown()
    }

    private func settings(presetId: String = "openai", model: String) -> ProviderSettings {
        var settings = ProviderSettings()
        settings.presetId = presetId
        settings.model = model
        return settings
    }

    /// The model-autoselect contract, enforced from the background path: an
    /// unset model is a deliberate state, and nothing unattended may fill it in
    /// or fall back to the preset default.
    func testAnUnsetModelFiresNoRequestFromTheBackgroundTask() async {
        let attempted = await BackgroundWorkCoordinator.shared.refreshSuggestions(
            settings: settings(model: ""), savedAppCount: 3
        )
        XCTAssertFalse(attempted)
        XCTAssertEqual(RequestCounter.count, 0)
    }

    /// The toggle is part of the same gate; a background wake-up is not a way
    /// around it.
    func testTheDisabledToggleFiresNoRequestFromTheBackgroundTask() async {
        UserDefaults.standard.set(false, forKey: AppPreferences.smartSuggestionsKey)
        let attempted = await BackgroundWorkCoordinator.shared.refreshSuggestions(
            settings: settings(model: "gpt-4.1"), savedAppCount: 3
        )
        XCTAssertFalse(attempted)
        XCTAssertEqual(RequestCounter.count, 0)
    }

    /// Local runtimes keep the static chips — and a background task must not
    /// wake an MLX model or poke a LAN gateway that may not be there.
    func testLocalRuntimesFireNoRequestFromTheBackgroundTask() async {
        for preset in ["mlx", "ollama"] {
            let attempted = await BackgroundWorkCoordinator.shared.refreshSuggestions(
                settings: settings(presetId: preset, model: "qwen3:4b"), savedAppCount: 1
            )
            XCTAssertFalse(attempted, preset)
        }
        XCTAssertEqual(RequestCounter.count, 0)
    }

    /// End-to-end through the real handler: with the toggle off, a full
    /// BGAppRefreshTask run completes and spends nothing.
    func testAFullRefreshRunCompletesWithoutSpendingAnything() async {
        UserDefaults.standard.set(false, forKey: AppPreferences.smartSuggestionsKey)
        let task = FakeTask()
        BackgroundWorkCoordinator.shared.handleRefresh(task)
        for _ in 0..<200 where task.completions.isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(RequestCounter.count, 0)
        XCTAssertEqual(task.completions, [true], "the task never reported back to iOS")
    }
}

// MARK: - Media sweep refusals

@MainActor
final class BackgroundMediaSweepTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-sweep-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PendingTurnStore.directoryOverride = directory
        BackgroundTurnGuard.disableSystemTaskForTesting = true
    }

    override func tearDown() {
        BackgroundTurnGuard.shared.end()
        BackgroundTurnGuard.disableSystemTaskForTesting = false
        PendingTurnStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func checkpoint() -> PendingTurn {
        PendingTurn(
            threadId: UUID(),
            userText: "bau mir eine Todo-App",
            turnStartIndex: 0,
            repairPasses: 0,
            startedAt: Date(),
            updatedAt: Date(),
            partialAssistantText: ""
        )
    }

    /// The resume affordance owns that checkpoint; a housekeeping pass must not
    /// delete the media its replay would show. (It also must not *resume* it —
    /// nothing in the background path touches TurnRestorePolicy.)
    func testACheckpointedTurnBlocksTheSweep() {
        PendingTurnStore.save(checkpoint())
        XCTAssertEqual(BackgroundWorkCoordinator.shared.sweepMedia(), .skippedTurnInFlight)
    }

    func testAnActiveTurnGrantBlocksTheSweep() {
        BackgroundTurnGuard.shared.begin {}
        XCTAssertEqual(BackgroundWorkCoordinator.shared.sweepMedia(), .skippedTurnInFlight)
    }

    func testWithNoTurnInPlayTheSweepIsAllowedToProceed() {
        PendingTurnStore.clear()
        XCTAssertNotEqual(BackgroundWorkCoordinator.shared.sweepMedia(), .skippedTurnInFlight)
    }
}

// MARK: - What the sweep considers referenced

final class PersistedMediaIdTests: XCTestCase {
    private struct ArchiveMirror: Codable {
        var threads: [ChatThread]
        var activeThreadId: UUID
    }

    private func archive(_ threads: [ChatThread]) -> Data {
        let mirror = ArchiveMirror(
            threads: threads, activeThreadId: threads.first?.id ?? UUID()
        )
        return (try? JSONEncoder().encode(mirror)) ?? Data()
    }

    func testEveryThreadContributesItsMediaIds() throws {
        let first = ChatThread(messages: [
            ChatMessage(role: .assistant, text: "Bild", mediaIds: ["a.png"]),
            ChatMessage(role: .user, text: "noch eins"),
        ])
        let second = ChatThread(messages: [
            ChatMessage(role: .assistant, text: "Video", mediaIds: ["b.videourl", "a.png"]),
        ])
        let ids = try XCTUnwrap(ChatSession.mediaIds(inArchive: archive([first, second])))
        XCTAssertEqual(ids, ["a.png", "b.videourl"])
    }

    /// THE data-safety rule of the whole sweep: an archive that will not decode
    /// must read as "unknown", never as "nothing is referenced" — the latter
    /// deletes every image the user owns.
    func testAnUndecodableArchiveIsNilAndNotAnEmptySet() {
        XCTAssertNil(ChatSession.mediaIds(inArchive: Data("not json".utf8)))
        XCTAssertNil(ChatSession.mediaIds(inArchive: Data()))
        XCTAssertNil(ChatSession.mediaIds(inArchive: Data(#"{"threads":"nope"}"#.utf8)))
    }

    func testAnEmptyButValidArchiveReferencesNothing() throws {
        let ids = try XCTUnwrap(ChatSession.mediaIds(inArchive: archive([])))
        XCTAssertTrue(ids.isEmpty)
    }
}

// MARK: - Temp export sweep

final class TemporaryExportSweeperTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-temp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        TemporaryExportSweeper.directoryOverride = directory
    }

    override func tearDown() {
        TemporaryExportSweeper.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @discardableResult
    private func write(_ name: String, ageInDays: Double) -> URL {
        let url = directory.appendingPathComponent(name)
        try? Data("x".utf8).write(to: url)
        let modified = Date().addingTimeInterval(-ageInDays * 24 * 60 * 60)
        try? FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path
        )
        return url
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    func testOnlyFilesThisAppWroteAreEvenCandidates() {
        XCTAssertTrue(TemporaryExportSweeper.isOwned("aiity-backup.json"))
        XCTAssertTrue(TemporaryExportSweeper.isOwned("aiity-diagnose-2026-08-09T10-00-00Z.txt"))
        XCTAssertTrue(TemporaryExportSweeper.isOwned("miniapp-downloads"))
        // tmp is shared with URLSession and other system machinery.
        XCTAssertFalse(TemporaryExportSweeper.isOwned("CFNetworkDownload_ab12.tmp"))
        XCTAssertFalse(TemporaryExportSweeper.isOwned("com.apple.something"))
    }

    func testStaleExportsGoAndForeignFilesStayEvenWhenOlder() {
        write("aiity-backup.json", ageInDays: 3)
        write("aiity-diagnose-old.txt", ageInDays: 9)
        write("CFNetworkDownload_ab12.tmp", ageInDays: 30)

        XCTAssertEqual(TemporaryExportSweeper.prune(), 2)
        XCTAssertFalse(exists("aiity-backup.json"))
        XCTAssertFalse(exists("aiity-diagnose-old.txt"))
        XCTAssertTrue(exists("CFNetworkDownload_ab12.tmp"))
    }

    /// A share sheet may still be holding a file written moments ago.
    func testFreshExportsAreKept() {
        write("aiity-backup.json", ageInDays: 0)
        XCTAssertEqual(TemporaryExportSweeper.prune(), 0)
        XCTAssertTrue(exists("aiity-backup.json"))
    }

    func testAMissingDirectoryIsNotAnError() {
        TemporaryExportSweeper.directoryOverride = directory
            .appendingPathComponent("does-not-exist")
        XCTAssertEqual(TemporaryExportSweeper.prune(), 0)
    }
}
