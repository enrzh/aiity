import XCTest
import WebKit
import SwiftData
@testable import AIApp

/// The pass that reconciles both things a mini-app leaves behind outside its
/// record — the browser cookie jar on disk and the consent grant in
/// `UserDefaults` — against the records that are still live. Every test here
/// drives the ownership decision, never WebKit and never the real defaults: the
/// two `WKWebsiteDataStore` class APIs sit behind `StoreIndex` because they are
/// fatal without `WebKitRuntime` initialisation and because they operate on the
/// test host's REAL on-disk stores, and revocation is injected for the same
/// reason (the unit host shares its container with the UI runs).
///
/// The asymmetry these tests defend: leaving a stale jar one more cycle is a
/// privacy wart, deleting a live app's jar destroys the user's site logins with
/// no way back. So most of them assert that nothing is reaped. Grants lean the
/// same way but less far — wrongly revoking one only re-prompts the user, while
/// wrongly keeping one is the silent privilege escalation the consent system
/// exists to prevent.
@MainActor
final class MiniAppSessionStoreSweepTests: XCTestCase {

    private func store(for id: String) -> UUID {
        MiniAppRunnerView.sessionStoreID(for: id)
    }

    // MARK: - Hermetic state
    //
    // Both kinds of state these tests touch are global to the DEVICE, not to
    // the test: the persistent `WKWebsiteDataStore` directories that
    // `fetchAllDataStoreIdentifiers` enumerates, and the consent map in the
    // shared `UserDefaults` — the unit host runs in the app's own container,
    // and nothing resets either between tests or between runs.
    //
    // That is not mere litter, and it is what made this class fail only when
    // run whole. A jar this class creates survives the process: even a
    // *successful* `remove(forIdentifier:)` can leave a residual store
    // directory behind, which the NEXT process enumerates as a data store
    // again. Those extras land in the sweep's doomed batch, and removing them
    // alongside a jar this process still has open makes WebKit answer
    // "Failed to delete files on disk" (WKWebSiteDataStore code 1) for the
    // freshly written one — an error the shipped sweep deliberately ignores.
    // The orphan then survives a sweep that reported reaping it, and
    // `testTheRealWebKitSweepRemovesTheOrphanedJarAndKeepsTheLiveOne` fails on
    // a device state no test in it ever created.
    //
    // So: every test snapshots and clears the consent map and puts it back in
    // `tearDown`; the two real-WebKit tests account for every identifier on
    // disk before they sweep — theirs plus whatever they inherited, which they
    // give a live record so it cannot be doomed — and `tearDown` takes the jars
    // back off disk, on failure too, which the old inline cleanup at the end of
    // the test body could not.

    /// The consent map exactly as this test found it, restored in `tearDown`.
    private var grantsBeforeTest: [String: MiniAppCapability] = [:]
    /// The durable purge queue as this test found it, restored the same way and
    /// for the same reason: it lives in the shared `UserDefaults`, and an entry
    /// left behind by one test makes the NEXT one enumerate WebKit at all (the
    /// queue is a trigger for the store half, exactly so a jar whose grant is
    /// already revoked still gets retried).
    private var purgesBeforeTest: [MiniAppSessionStorePurgeQueue.Record] = []
    /// Set by `usingRealDataStores()`, so `tearDown` only brings WebKit up for
    /// the two tests that already use it.
    private var usesRealDataStores = false
    /// The sweep's third resource reads a real directory by default
    /// (`MiniAppRevisionStore.baseDirectory`), and the test host shares its
    /// container with the app — so every test runs against its own empty temp
    /// directory instead, restored in `tearDown` like the consent map.
    private var revisionsBaseBeforeTest: URL!
    private var revisionsTempDirectory: URL!
    /// Resources four and five (bridge storage, notification ledger) read real
    /// state through their defaults exactly like revisions — redirected per
    /// test for the same reason: fake record sets in these tests must never
    /// wipe the app's actual mini-app storage or cancel real notifications.
    private var storageRootBeforeTest: URL?
    private var storageTempDirectory: URL!
    private var scheduledAppsBeforeTest: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        grantsBeforeTest = MiniAppConsent.grants()
        for appId in grantsBeforeTest.keys { MiniAppConsent.revoke(appId: appId) }
        purgesBeforeTest = MiniAppSessionStorePurgeQueue.records()
        MiniAppSessionStorePurgeQueue.removeAll()
        revisionsBaseBeforeTest = MiniAppRevisionStore.baseDirectory
        revisionsTempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-revisions-\(UUID().uuidString)", isDirectory: true)
        MiniAppRevisionStore.baseDirectory = revisionsTempDirectory
        storageRootBeforeTest = MiniAppStorage.rootOverride
        storageTempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-storage-\(UUID().uuidString)", isDirectory: true)
        MiniAppStorage.rootOverride = storageTempDirectory
        scheduledAppsBeforeTest = MiniAppNotificationScheduler.scheduledAppIds()
        MiniAppNotificationScheduler.replaceScheduledAppIds([])
    }

    override func tearDown() async throws {
        MiniAppNotificationScheduler.replaceScheduledAppIds(scheduledAppsBeforeTest)
        scheduledAppsBeforeTest = []
        MiniAppStorage.rootOverride = storageRootBeforeTest
        try? FileManager.default.removeItem(at: storageTempDirectory)
        MiniAppRevisionStore.baseDirectory = revisionsBaseBeforeTest
        try? FileManager.default.removeItem(at: revisionsTempDirectory)
        if usesRealDataStores {
            // Everything, not just ours: whatever is on disk when this test
            // ends is what the next one — and the next process — would sweep.
            _ = await purgeDataStores(await allIdentifiers())
            usesRealDataStores = false
        }
        for appId in MiniAppConsent.grants().keys { MiniAppConsent.revoke(appId: appId) }
        for (appId, capability) in grantsBeforeTest {
            MiniAppConsent.allow(appId: appId, capability: capability)
        }
        grantsBeforeTest = [:]
        MiniAppSessionStorePurgeQueue.replaceAll(purgesBeforeTest)
        purgesBeforeTest = []
        try await super.tearDown()
    }

    /// Marks this test as one that puts real jars on disk, so `tearDown` takes
    /// them off again.
    private func usingRealDataStores() {
        usesRealDataStores = true
        WebKitRuntime.ensureInitialised()
    }

    /// Everything on disk that is not one of `mine` — the jars an earlier test
    /// in this process, or an earlier run, left behind.
    ///
    /// These are NOT deleted here, and that is the whole point. A store this
    /// process has already opened stays live for the lifetime of the process:
    /// WebKit answers `remove(forIdentifier:)` for it with "Failed to delete
    /// files on disk", and deleting it anyway only makes it reappear in the
    /// enumeration a moment later. So instead of fighting for an empty disk,
    /// the caller gives each of these a live `MiniApp` record. Owned means not
    /// doomed, which leaves the sweep under test exactly ONE identifier to
    /// reap — the orphan the test made on purpose — no matter what ran before.
    ///
    /// That one-identifier batch is the property this class needs. Reaping a
    /// jar this process still holds open alongside other jars is what made
    /// WebKit fail the orphan's removal, silently, in a sweep that reported
    /// having reaped it.
    private func inheritedStores(besides mine: [UUID]) async -> [UUID] {
        Set(await allIdentifiers()).subtracting(mine).sorted { $0.uuidString < $1.uuidString }
    }

    /// Whether WebKit has stopped listing `identifier` — the reading the sweep
    /// is judged on.
    ///
    /// Bounded, and it ends the instant the jar is gone. This is not a retry of
    /// the behaviour under test and not a sleep for its own sake: the sweep has
    /// already run and nothing else in this process deletes jars, so the only
    /// thing that can make the identifier disappear is the removal being
    /// asserted. `remove(forIdentifier:)` fires its completion handler before
    /// `fetchAllDataStoreIdentifiers` is guaranteed to agree, and on a loaded
    /// machine it does not. A jar still listed at the deadline fails the test
    /// exactly as an immediate check would.
    private func jarDisappeared(_ identifier: UUID, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if !(await allIdentifiers()).contains(identifier) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Gives each identifier a live record, so the sweep counts it as owned —
    /// an app whose record still exists is exactly what "not this test's
    /// orphan" means to the code under test.
    private func adopt(_ identifiers: [UUID], into context: ModelContext) throws {
        for identifier in identifiers {
            let squatter = MiniApp(name: "Vorlauf", emoji: "📦", html: "<html>x</html>")
            squatter.id = identifier
            context.insert(squatter)
        }
        try context.save()
    }

    /// Removes `identifiers` and does not return until WebKit stops listing
    /// them, answering with whatever refused to go.
    ///
    /// One `remove(forIdentifier:)` call is not enough to know a jar is gone:
    /// it reports success while leaving a residual directory the next process
    /// enumerates, and it fails outright for a store this process still holds
    /// open. So removal is driven until `fetchAllDataStoreIdentifiers` — the
    /// same reading the test asserts on — agrees. This is housekeeping, never a
    /// retry of the behaviour under test: the sweep's own removal is still
    /// asserted exactly once, immediately after `run` returns.
    @discardableResult
    private func purgeDataStores(_ identifiers: [UUID], timeout: TimeInterval = 5) async -> [UUID] {
        guard !identifiers.isEmpty else { return [] }
        WebKitRuntime.ensureInitialised()
        var remaining = identifiers
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            for identifier in remaining {
                await withCheckedContinuation { continuation in
                    WKWebsiteDataStore.remove(forIdentifier: identifier) { _ in continuation.resume() }
                }
            }
            let onDisk = Set(await allIdentifiers())
            remaining = remaining.filter { onDisk.contains($0) }
            if remaining.isEmpty || Date() >= deadline { return remaining }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MiniApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: - Ownership (pure)

    func testAJarWhoseMiniAppStillExistsIsKept() {
        let app = UUID()
        let doomed = MiniAppSessionStoreSweep.plan(
            found: [store(for: app.uuidString)],
            liveAppIds: [app],
            consentedIds: [app.uuidString],
            mode: .synced,
            initialImportComplete: true
        )
        XCTAssertEqual(doomed, [], "a live record must protect its cookie jar")
    }

    func testAJarWithNoLiveRecordIsReaped() {
        let gone = UUID()
        let alive = UUID()
        let doomed = MiniAppSessionStoreSweep.plan(
            found: [store(for: gone.uuidString), store(for: alive.uuidString)],
            liveAppIds: [alive],
            // The grant survives a delete that happened on another device —
            // it must NOT be what keeps the jar alive.
            consentedIds: [gone.uuidString, alive.uuidString],
            mode: .synced,
            initialImportComplete: true
        )
        XCTAssertEqual(doomed, [store(for: gone.uuidString)])
    }

    /// An identifier that maps to nothing we know about at all — a jar from an
    /// older build, or one whose grant was already revoked while the delete
    /// failed. Nothing owns it, so it goes.
    func testAnUnknownIdentifierIsReaped() {
        let stranger = UUID()
        let doomed = MiniAppSessionStoreSweep.plan(
            found: [stranger],
            liveAppIds: [UUID()],
            consentedIds: [MiniAppConsent.previewId(html: "<html>x</html>")],
            mode: .localOnly,
            initialImportComplete: true
        )
        XCTAssertEqual(doomed, [stranger])
    }

    /// A chat preview has no library record by definition and is keyed by a
    /// content hash, so it can only be recognised through its consent grant.
    /// Reaping it would log the user out of a preview they can still reopen
    /// from the persisted transcript.
    func testAPreviewKeyedAppIsNotReaped() {
        let previewId = MiniAppConsent.previewId(html: "<html>browser preview</html>")
        let doomed = MiniAppSessionStoreSweep.plan(
            found: [store(for: previewId)],
            liveAppIds: [],
            consentedIds: [previewId],
            mode: .synced,
            initialImportComplete: true
        )
        XCTAssertEqual(doomed, [], "a preview's grant is the only owner it can have")
    }

    func testTwoPreviewsDoNotProtectEachOther() {
        let kept = MiniAppConsent.previewId(html: "<html>A</html>")
        let gone = MiniAppConsent.previewId(html: "<html>B</html>")
        let doomed = MiniAppSessionStoreSweep.plan(
            found: [store(for: kept), store(for: gone)],
            liveAppIds: [],
            consentedIds: [kept],
            mode: .localOnly,
            initialImportComplete: true
        )
        XCTAssertEqual(doomed, [store(for: gone)])
    }

    func testNothingOnDiskMeansNothingToDo() {
        let doomed = MiniAppSessionStoreSweep.plan(
            found: [],
            liveAppIds: [UUID()],
            consentedIds: [],
            mode: .synced,
            initialImportComplete: true
        )
        XCTAssertEqual(doomed, [])
    }

    // MARK: - The CloudKit race

    func testNothingIsReapedWhileTheFirstImportIsStillRunning() {
        let notYetImported = UUID()
        let doomed = MiniAppSessionStoreSweep.plan(
            found: [store(for: notYetImported.uuidString)],
            liveAppIds: [],
            consentedIds: [notYetImported.uuidString],
            mode: .synced,
            initialImportComplete: false
        )
        XCTAssertEqual(doomed, [], "an unimported record must not look like a deleted one")
    }

    func testLocalOnlyMaySweepImmediately() {
        XCTAssertTrue(MiniAppSessionStoreSweep.mayCompare(mode: .localOnly, initialImportComplete: true),
                      "nothing remote is coming, so this device's records are the whole library")
    }

    /// A relocated store shows an empty library while CloudKit still holds the
    /// records — the one case where "no record" is loudest and most wrong.
    func testARecoveredOrInMemoryStoreNeverSweeps() {
        for mode in [SyncStatus.Mode.recovered, .inMemory] {
            XCTAssertFalse(MiniAppSessionStoreSweep.mayCompare(mode: mode, initialImportComplete: true))
            XCTAssertEqual(
                MiniAppSessionStoreSweep.plan(
                    found: [UUID()], liveAppIds: [], consentedIds: [],
                    mode: mode, initialImportComplete: true
                ),
                []
            )
        }
    }

    // MARK: - Grant ownership (pure)

    func testAGrantWhoseRecordStillExistsIsKept() {
        let app = UUID()
        XCTAssertEqual(
            MiniAppSessionStoreSweep.staleGrantIds(
                grantIds: [app.uuidString], liveAppIds: [app],
                mode: .synced, initialImportComplete: true
            ),
            []
        )
    }

    /// The escalation this whole pass exists for: the record went away through
    /// CloudKit mirroring, so the library's delete alert — the only other
    /// caller of `revoke` — never ran, and the grant would silently re-arm the
    /// app if a record with that UUID ever came back.
    func testAGrantWithNoLiveRecordIsRevoked() {
        let gone = UUID()
        let alive = UUID()
        XCTAssertEqual(
            MiniAppSessionStoreSweep.staleGrantIds(
                grantIds: [gone.uuidString, alive.uuidString], liveAppIds: [alive],
                mode: .synced, initialImportComplete: true
            ),
            [gone.uuidString]
        )
    }

    /// A chat preview is keyed by a hash of its HTML and has no library record
    /// BY DESIGN, so "no record" is not evidence of anything. It stays
    /// re-openable from the persisted transcript, and revoking would re-prompt
    /// for a consent the user already gave.
    func testAPreviewGrantIsNeverRevoked() {
        let preview = MiniAppConsent.previewId(html: "<html>preview</html>")
        XCTAssertEqual(
            MiniAppSessionStoreSweep.staleGrantIds(
                grantIds: [preview, "legacy-preview", ""], liveAppIds: [],
                mode: .localOnly, initialImportComplete: true
            ),
            [],
            "non-UUID keys are previews and must never be touched"
        )
    }

    /// Grants are written with `UUID.uuidString` (uppercase), but a key that
    /// reached defaults lowercased must still find its record — matching goes
    /// through `UUID(uuidString:)`, not string equality.
    func testAGrantKeyIsMatchedAsAUUIDNotAsAString() {
        let app = UUID()
        XCTAssertEqual(
            MiniAppSessionStoreSweep.staleGrantIds(
                grantIds: [app.uuidString.lowercased()], liveAppIds: [app],
                mode: .localOnly, initialImportComplete: true
            ),
            []
        )
    }

    func testAnEmptyGrantMapRevokesNothing() {
        XCTAssertEqual(
            MiniAppSessionStoreSweep.staleGrantIds(
                grantIds: [], liveAppIds: [UUID()],
                mode: .synced, initialImportComplete: true
            ),
            []
        )
    }

    /// Exactly the gate the jar sweep uses — deliberately the same
    /// `mayCompare`, not a second notion of "safe to compare". Before the first
    /// import settles a missing record means "not here YET".
    func testNoGrantIsRevokedWhileTheFirstImportIsStillRunning() {
        let notYetImported = UUID()
        XCTAssertEqual(
            MiniAppSessionStoreSweep.staleGrantIds(
                grantIds: [notYetImported.uuidString], liveAppIds: [],
                mode: .synced, initialImportComplete: false
            ),
            []
        )
    }

    func testNoGrantIsRevokedOnARecoveredOrInMemoryStore() {
        for mode in [SyncStatus.Mode.recovered, .inMemory] {
            XCTAssertEqual(
                MiniAppSessionStoreSweep.staleGrantIds(
                    grantIds: [UUID().uuidString], liveAppIds: [],
                    mode: mode, initialImportComplete: true
                ),
                [],
                "\(mode)'s empty library is not evidence that the apps were deleted"
            )
        }
    }

    // MARK: - End to end, with WebKit behind the seam

    /// A WebKit that accepts every removal, unless `refusing` names it — the
    /// refusal is not an exotic case but the one WebKit gives for any store the
    /// current process has opened.
    private func fakeIndex(
        _ found: [UUID], removed: RemovalLog, refusing: Set<UUID> = []
    ) -> MiniAppSessionStoreSweep.StoreIndex {
        MiniAppSessionStoreSweep.StoreIndex(
            identifiers: { removed.events.append("list"); return found },
            remove: {
                removed.ids.append($0)
                removed.events.append("remove")
                return !refusing.contains($0)
            }
        )
    }

    /// Records both halves of the pass on ONE timeline, so the order between
    /// them is assertable and not just the sum of two counts.
    @MainActor final class RemovalLog {
        var ids: [UUID] = []
        var revoked: [String] = []
        var events: [String] = []

        func revoke(_ appId: String) {
            revoked.append(appId)
            events.append("revoke")
        }
    }

    /// Jars that actually disappear when removed, so a second pass sees the
    /// state the first one left.
    @MainActor final class FakeDisk {
        var jars: Set<UUID>
        init(jars: Set<UUID>) { self.jars = jars }
    }

    func testRunRemovesOnlyTheOrphanedJar() async throws {
        let context = try makeContext()
        let live = MiniApp(name: "Bank", emoji: "🏦", html: "<html>b</html>")
        context.insert(live)
        try context.save()
        let orphan = UUID()

        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)
        let log = RemovalLog()
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: [live.id.uuidString: .browser, orphan.uuidString: .browser],
            index: fakeIndex([store(for: live.id.uuidString), store(for: orphan.uuidString)],
                             removed: log),
            revoke: log.revoke
        )

        XCTAssertEqual(outcome.stores, .swept(reaped: 1, kept: 1, deferred: 0, residual: 0))
        XCTAssertEqual(log.ids, [store(for: orphan.uuidString)])
        XCTAssertEqual(outcome.revokedGrants, [orphan.uuidString],
                       "the same mirrored delete leaks the grant, not just the jar")
        XCTAssertEqual(log.revoked, [orphan.uuidString])
    }

    /// The common case: nobody ever granted browser tier, so no persistent
    /// store can exist and WebKit must not be brought up at launch for it. The
    /// grant half still runs — a `.network` grant leaves no jar behind but is
    /// exactly as capable of silently re-arming a returning record.
    func testRunNeverEnumeratesStoresWithoutABrowserGrant() async throws {
        let context = try makeContext()
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)
        let gone = UUID()
        let log = RemovalLog()
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: ["some-preview": .network, gone.uuidString: .network],
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: {
                    XCTFail("must not enumerate stores when no browser grant exists")
                    return []
                },
                remove: { log.ids.append($0); return true }
            ),
            revoke: log.revoke
        )
        XCTAssertEqual(outcome.stores, .skippedNoBrowserGrants)
        XCTAssertEqual(log.ids, [])
        XCTAssertEqual(outcome.revokedGrants, [gone.uuidString])
    }

    /// Nothing granted at all: the whole pass is a no-op and WebKit stays out
    /// of the launch path.
    func testRunSkipsEntirelyWithNoGrants() async throws {
        let context = try makeContext()
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)
        let log = RemovalLog()
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: [:],
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: {
                    XCTFail("must not enumerate stores when nothing was ever granted")
                    return []
                },
                remove: { log.ids.append($0); return true }
            ),
            records: { _ in XCTFail("must not even read the library"); return [] },
            revoke: log.revoke
        )
        XCTAssertEqual(outcome, MiniAppSessionStoreSweep.Outcome(stores: .skippedNoGrants))
        XCTAssertEqual(log.events, [])
    }

    // MARK: - Ordering: jars before grants, in one pass

    /// The hazard: the jar sweep's cheapest gate is
    /// `grants.values.contains(.browser)`, and the grant sweep deletes from
    /// that same map. Here the ONLY browser grant belongs to the mirror-deleted
    /// app — so if revocation ran first (or from an earlier, separate caller),
    /// the jar sweep would see no browser grant, skip, and strand real site
    /// logins on disk forever. Assert the timeline directly, not just the
    /// totals.
    func testTheOrphanedJarIsReapedBeforeItsGrantIsRevoked() async throws {
        let context = try makeContext()
        let gone = UUID()
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)
        let log = RemovalLog()

        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: [gone.uuidString: .browser],
            index: fakeIndex([store(for: gone.uuidString)], removed: log),
            revoke: log.revoke
        )

        XCTAssertEqual(log.events, ["list", "remove", "revoke"],
                       "the jar must be reaped BEFORE the grant that gates the sweep is revoked")
        XCTAssertEqual(outcome.stores, .swept(reaped: 1, kept: 0, deferred: 0, residual: 0))
        XCTAssertEqual(outcome.revokedGrants, [gone.uuidString])
    }

    /// The other side of the same constraint: once the pass has run, the grant
    /// is gone — so there is no second launch that could still reap the jar.
    /// If the order above ever flipped, this is the state the user would be
    /// stuck in permanently, with the jar still on disk.
    func testTheSecondPassAfterRevocationHasNoJarLeftToStrand() async throws {
        let context = try makeContext()
        let gone = UUID()
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)

        // Pass one, on the real defaults' shape: one browser grant, no record.
        var grants: [String: MiniAppCapability] = [gone.uuidString: .browser]
        let disk = FakeDisk(jars: [store(for: gone.uuidString)])
        let first = RemovalLog()
        let firstOutcome = await MiniAppSessionStoreSweep.run(
            context: context, status: status, grants: grants,
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: { Array(disk.jars) },
                remove: { disk.jars.remove($0); first.ids.append($0); return true }
            ),
            revoke: first.revoke
        )
        for revoked in firstOutcome.revokedGrants { grants.removeValue(forKey: revoked) }
        XCTAssertTrue(disk.jars.isEmpty, "pass one must take the jar with it")

        // Pass two, next launch, reading the grants pass one left behind. The
        // grant is gone, so the only reason this pass looks at all is the
        // tombstone pass one's successful removal left in the purge queue — and
        // looking is the point: a removal WebKit accepts still leaves a stub
        // directory that only a LATER process can see, so exactly one confirming
        // enumeration follows every reap. Nothing is on disk here, so nothing is
        // swept and the tombstone is dropped.
        let second = RemovalLog()
        let secondOutcome = await MiniAppSessionStoreSweep.run(
            context: context, status: status, grants: grants,
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: { second.events.append("list"); return Array(disk.jars) },
                remove: { second.ids.append($0); return true }
            ),
            revoke: second.revoke
        )
        XCTAssertEqual(secondOutcome.stores, .swept(reaped: 0, kept: 0, deferred: 0, residual: 0))
        XCTAssertEqual(second.ids, [], "there was nothing left on disk to remove")
        XCTAssertTrue(MiniAppSessionStorePurgeQueue.isEmpty)

        // Pass three, the launch after that: no grant, nothing owed, so the
        // whole pass — and WebKit — stays out of the launch path again.
        let third = RemovalLog()
        let thirdOutcome = await MiniAppSessionStoreSweep.run(
            context: context, status: status, grants: grants,
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: { XCTFail("no grant and nothing owed, so no sweep"); return [] },
                remove: { third.ids.append($0); return true }
            ),
            revoke: third.revoke
        )
        XCTAssertEqual(thirdOutcome.stores, .skippedNoGrants)
        XCTAssertEqual(third.events, [])
    }

    // MARK: - An unreadable library is not an empty one

    func testRunRevokesNothingWhenTheLibraryCannotBeRead() async throws {
        let context = try makeContext()
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)
        let log = RemovalLog()

        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: [UUID().uuidString: .browser, UUID().uuidString: .network],
            index: fakeIndex([UUID()], removed: log),
            records: { _ in nil },      // the fetch threw
            revoke: log.revoke
        )

        XCTAssertEqual(outcome.stores, .skippedUnreadableLibrary)
        XCTAssertEqual(outcome.revokedGrants, [],
                       "a failed fetch must never be read as 'every app was deleted'")
        XCTAssertEqual(log.events, [])
    }

    /// The one test that uses WebKit for real: it creates two persistent
    /// cookie jars on disk, gives only one of them a live `MiniApp`, and runs
    /// the shipped `StoreIndex.webKit` over them. Everything above proves the
    /// arithmetic; this proves the actual `fetchAllDataStoreIdentifiers` /
    /// `remove(forIdentifier:)` pair does what the arithmetic says — the exact
    /// shape of a mini-app deleted on another device (record gone, no alert,
    /// jar left behind).
    func testTheRealWebKitSweepRemovesTheOrphanedJarAndKeepsTheLiveOne() async throws {
        usingRealDataStores()
        let keeper = UUID()
        let orphan = UUID()
        // Real UUID app ids pass through `sessionStoreID` unchanged, so these
        // are also the store identifiers.
        try await writeCookie(into: store(for: keeper.uuidString), name: "keep")
        try await writeCookie(into: store(for: orphan.uuidString), name: "orphan")

        var onDisk = await allIdentifiers()
        guard onDisk.contains(store(for: keeper.uuidString)),
              onDisk.contains(store(for: orphan.uuidString)) else {
            throw XCTSkip("WebKit did not persist the test data stores in this environment")
        }
        let inherited = await inheritedStores(besides: [store(for: keeper.uuidString),
                                                        store(for: orphan.uuidString)])

        let context = try makeContext()
        let live = MiniApp(name: "Bank", emoji: "🏦", html: "<html>b</html>")
        live.id = keeper                      // the record the orphan does NOT have
        context.insert(live)
        try context.save()
        try adopt(inherited, into: context)
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)

        let log = RemovalLog()
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: [keeper.uuidString: .browser, orphan.uuidString: .browser],
            index: .webKit,
            revoke: log.revoke          // never the shared defaults from a test
        )

        onDisk = await allIdentifiers()
        XCTAssertTrue(onDisk.contains(store(for: keeper.uuidString)),
                      "the live app's logins must survive the sweep")

        // What the sweep PROMISES about an orphan is that it is never silently
        // kept — not that WebKit deletes it this instant. WebKit refuses to
        // delete a store the current process has opened, and this test opened
        // the orphan's when it wrote the cookie, so whether the removal lands
        // now or is deferred to the next launch is WebKit's call, not ours.
        // Asserting `reaped: 1, deferred: 0` asserted the timing and failed
        // intermittently; this asserts the contract the purge queue exists for.
        let orphanIsGone = await jarDisappeared(store(for: orphan.uuidString))
        guard case let .swept(reaped, kept, deferred, residual) = outcome.stores else {
            return XCTFail("the sweep must report a partition, got \(outcome.stores)")
        }
        XCTAssertEqual(kept, inherited.count + 1,
                       "only the live app's jar is kept — the orphan is never in `kept`")
        XCTAssertEqual(reaped + deferred, 1, "the orphan is acted on exactly once")
        XCTAssertEqual(residual, 0, "nothing here is a leftover from an earlier removal")
        if reaped == 1 {
            XCTAssertTrue(orphanIsGone, "a jar counted as reaped must actually be gone")
        } else {
            XCTAssertTrue(
                MiniAppSessionStorePurgeQueue.records().contains {
                    $0.identifier == store(for: orphan.uuidString) && $0.state == .pending
                },
                "a refused removal must stay owed in the durable queue, or the jar strands forever"
            )
        }
        XCTAssertEqual(log.revoked, [orphan.uuidString],
                       "the same pass must take the orphan's grant, not only its jar")
        // The keeper's jar goes in `tearDown`, which also runs when an
        // assertion above fails — leaving it behind is what poisoned the next
        // process.
    }

    /// The whole leak, end to end, with NOTHING faked but the sync mode: a real
    /// consent grant in `UserDefaults`, a real cookie jar on disk, a real
    /// SwiftData fetch, the shipped `StoreIndex.webKit` and the shipped
    /// `MiniAppConsent.revoke`. Reproduces a mirrored delete exactly — the
    /// record is simply never there, so `LibraryView`'s alert (the only other
    /// revoker) never runs — and proves BOTH halves land: the grant that would
    /// have silently re-armed the app is gone, AND the jar it was gating went
    /// with it rather than being stranded by an early revocation.
    func testTheShippedPathRevokesTheRealGrantAndReapsTheRealJar() async throws {
        usingRealDataStores()
        let keeper = UUID()
        let orphan = UUID()
        // `setUp` emptied the real consent map and `tearDown` puts the user's
        // own grants back, so these two are the whole map the shipped
        // `MiniAppConsent.grants()` default hands the pass.
        MiniAppConsent.allow(appId: keeper.uuidString, capability: .browser)
        MiniAppConsent.allow(appId: orphan.uuidString, capability: .browser)
        try await writeCookie(into: store(for: keeper.uuidString), name: "keep")
        try await writeCookie(into: store(for: orphan.uuidString), name: "orphan")

        var onDisk = await allIdentifiers()
        guard onDisk.contains(store(for: keeper.uuidString)),
              onDisk.contains(store(for: orphan.uuidString)) else {
            throw XCTSkip("WebKit did not persist the test data stores in this environment")
        }
        let inherited = await inheritedStores(besides: [store(for: keeper.uuidString),
                                                        store(for: orphan.uuidString)])

        let context = try makeContext()
        let live = MiniApp(name: "Bank", emoji: "🏦", html: "<html>b</html>")
        live.id = keeper
        context.insert(live)
        try context.save()
        try adopt(inherited, into: context)
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)

        // Only `context` and `status` are supplied — grants, the store index,
        // the record fetch and the revocation are all the shipped defaults.
        let outcome = await MiniAppSessionStoreSweep.run(context: context, status: status)

        XCTAssertEqual(MiniAppConsent.granted(appId: orphan.uuidString), nil,
                       "the grant of a record that is gone must not survive the pass")
        XCTAssertEqual(MiniAppConsent.granted(appId: keeper.uuidString), .browser,
                       "the live app's own grant must be untouched")
        XCTAssertTrue(outcome.revokedGrants.contains(orphan.uuidString))
        XCTAssertFalse(outcome.revokedGrants.contains(keeper.uuidString))
        XCTAssertEqual(outcome.stores, .swept(reaped: 1, kept: inherited.count + 1, deferred: 0, residual: 0),
                       "exactly the orphan, and nothing else this test put on disk")

        onDisk = await allIdentifiers()
        XCTAssertTrue(onDisk.contains(store(for: keeper.uuidString)))
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.record(for: store(for: orphan.uuidString))?.state,
                       .residual,
                       "the accepted removal must stay tombstoned until WebKit confirms it is gone")
        // The keeper's jar and both grants go in `tearDown`, failure included.
    }

    /// A persistent store only reaches disk once something is written to it.
    /// The read-back is not decoration: it is the only thing that says the
    /// write reached the networking process before the sweep tries to delete
    /// the directory underneath it.
    @discardableResult
    private func writeCookie(into identifier: UUID, name: String) async throws -> WKWebsiteDataStore {
        let dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "example.com", .path: "/", .name: name, .value: "1",
            .expires: Date().addingTimeInterval(3600),
        ]))
        await dataStore.httpCookieStore.setCookie(cookie)
        let stored = await dataStore.httpCookieStore.allCookies()
        XCTAssertTrue(stored.contains { $0.name == name }, "the jar must really hold a login")
        return dataStore
    }

    private func allIdentifiers() async -> [UUID] {
        WebKitRuntime.ensureInitialised()
        return await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
        }
    }

    func testRunRefusesOnARecoveredStore() async throws {
        let context = try makeContext()
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.recovered)
        let log = RemovalLog()
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: [UUID().uuidString: .browser],
            index: fakeIndex([UUID()], removed: log),
            revoke: log.revoke
        )
        XCTAssertEqual(outcome, MiniAppSessionStoreSweep.Outcome(stores: .skippedUnsafeStorageMode))
        XCTAssertEqual(log.events, [], "a relocated store's empty library is not evidence of a delete")
    }

    // MARK: - Honest counts, and the purge that survives the process
    //
    // The gap these close: `remove(forIdentifier:)` FAILS for any data store the
    // current process has opened — "Failed to delete files on disk", every time,
    // for the lifetime of that process — and the shipped code discarded the
    // error and reported the attempt as a reap. The common delete is exactly
    // that shape (open a browser mini-app, then delete it), so the app was
    // routinely reporting a deletion of real site logins that never happened.

    /// `.swept(reaped:)` is a claim about what is gone, so a refused removal
    /// must land in `deferred`, not in `reaped`.
    func testSweptCountsOnlyTheRemovalsWebKitAccepted() async throws {
        let context = try makeContext()
        let live = MiniApp(name: "Bank", emoji: "🏦", html: "<html>b</html>")
        context.insert(live)
        try context.save()
        let goes = UUID()
        let refuses = UUID()

        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)
        let log = RemovalLog()
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: [live.id.uuidString: .browser,
                     goes.uuidString: .browser,
                     refuses.uuidString: .browser],
            index: fakeIndex(
                [store(for: live.id.uuidString),
                 store(for: goes.uuidString),
                 store(for: refuses.uuidString)],
                removed: log,
                refusing: [store(for: refuses.uuidString)]
            ),
            revoke: log.revoke
        )

        XCTAssertEqual(outcome.stores, .swept(reaped: 1, kept: 1, deferred: 1, residual: 0),
                       "the refused jar is still on disk — counting it as reaped is the lie")
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.record(for: store(for: refuses.uuidString))?.state,
                       .pending,
                       "what could not be deleted has to outlive the process that tried")
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.record(for: store(for: goes.uuidString))?.state,
                       .residual,
                       "a removal WebKit accepted is believed done, pending one confirming enumeration")
    }

    /// THE case that was broken, with the real WebKit: a store this process has
    /// open cannot be deleted here at all. Nothing may be reported as reaped, the
    /// identifier has to be written down durably, and the next launch — which is
    /// a fresh process, and crucially has NO grant left to gate the sweep on,
    /// because the same pass revoked it — has to finish the job.
    ///
    /// Against the shipped code this failed on the first assertion: it reported
    /// `.swept(reaped: 1, …)` with the cookies still on disk.
    func testAJarThisProcessHoldsOpenIsDeferredAndFinishedOnTheNextLaunch() async throws {
        usingRealDataStores()
        let orphan = UUID()
        let jar = store(for: orphan.uuidString)
        // Start from a disk this process has accounted for. Stores left by an
        // EARLIER process are not stable enough to count: WebKit lists a stale
        // stub directory on one enumeration and has tidied it away by the next,
        // which turns any `kept:` expectation derived from a snapshot into a
        // coin flip. (Seen: this test failed alone with `kept: 0` against a
        // snapshot of 1.) Anything that survives this purge is genuinely stuck
        // and is adopted below, exactly as the other real-WebKit tests do.
        _ = await purgeDataStores(await allIdentifiers())
        // Held for the whole test: an OPEN store is the state WebKit refuses to
        // delete, and it is the state every just-used mini-app is in.
        let open = try await writeCookie(into: jar, name: "orphan")

        guard await allIdentifiers().contains(jar) else {
            throw XCTSkip("WebKit did not persist the test data store in this environment")
        }
        let inherited = await inheritedStores(besides: [jar])

        let context = try makeContext()
        try adopt(inherited, into: context)
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)

        let log = RemovalLog()
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: [orphan.uuidString: .browser],
            index: .webKit,
            revoke: log.revoke
        )
        withExtendedLifetime(open) {}

        guard await allIdentifiers().contains(jar) else {
            throw XCTSkip("this WebKit deleted a store the process still holds open — "
                          + "the same-session case cannot be reproduced here")
        }
        XCTAssertEqual(outcome.stores, .swept(reaped: 0, kept: inherited.count,
                                              deferred: 1, residual: 0),
                       "the jar is still on disk with its cookies in it — nothing was reaped")
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.record(for: jar)?.state, .pending,
                       "the only way back to this jar is a note that outlives the process")
        XCTAssertEqual(log.revoked, [orphan.uuidString],
                       "the grant still goes — which is exactly why the note has to exist")

        // The next launch. A fresh process CAN delete it; modelled here by an
        // index that accepts, because a second process is not available inside
        // one test. Everything else is real: the same durable queue, and NO
        // grants at all, since the pass above revoked the only one.
        let disk = FakeDisk(jars: [jar])
        let next = RemovalLog()
        let nextOutcome = await MiniAppSessionStoreSweep.run(
            context: context, status: status, grants: [:],
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: { Array(disk.jars) },
                remove: { disk.jars.remove($0); next.ids.append($0); return true }
            ),
            revoke: next.revoke
        )
        XCTAssertEqual(nextOutcome.stores, .swept(reaped: 1, kept: 0, deferred: 0, residual: 0))
        XCTAssertEqual(next.ids, [jar], "the queue, not a grant, is what got the sweep to run")
        XCTAssertTrue(disk.jars.isEmpty)
    }

    /// The stranding hazard one level deeper than the grant/jar ordering: a
    /// refused removal whose grant is already gone is invisible to every gate
    /// the sweep has. The queue is the third trigger, and without it that jar
    /// would sit on disk forever.
    func testAQueuedPurgeMakesTheSweepRunWithNoGrantsLeft() async throws {
        let context = try makeContext()
        let jar = store(for: UUID().uuidString)
        MiniAppSessionStorePurgeQueue.note(jar)
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)

        let log = RemovalLog()
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context, status: status, grants: [:],
            index: fakeIndex([jar], removed: log), revoke: log.revoke
        )

        XCTAssertEqual(outcome.stores, .swept(reaped: 1, kept: 0, deferred: 0, residual: 0))
        XCTAssertEqual(log.ids, [jar])
    }

    /// The residual rule. A removal WebKit ACCEPTED still leaves a stub
    /// directory (`…/<uuid>/ResourceLoadStatistics`) that the next process
    /// enumerates as a data store. It has no owner, so it is doomed again — and
    /// without the tombstone it would be reported as a freshly reaped cookie jar
    /// on every launch, forever. It is swept again so the stub goes, and counted
    /// apart from both `reaped` and `kept`.
    func testAnIdentifierAlreadyRemovedOnceCountsAsResidualNotAsAReap() async throws {
        let context = try makeContext()
        let jar = store(for: UUID().uuidString)
        MiniAppSessionStorePurgeQueue.note(jar)
        MiniAppSessionStorePurgeQueue.recordAttempt(jar, succeeded: true)
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)

        let log = RemovalLog()
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context, status: status, grants: [:],
            index: fakeIndex([jar], removed: log), revoke: log.revoke
        )

        XCTAssertEqual(outcome.stores, .swept(reaped: 0, kept: 0, deferred: 0, residual: 1),
                       "leftovers of a completed deletion are not a jar that was there to lose")
        XCTAssertEqual(log.ids, [jar], "the stub is still swept, or it never goes away")
    }

    /// And it converges: the first launch that does not enumerate the identifier
    /// forgets it, so the tombstone cannot accumulate.
    func testAResidualIsForgottenOnceWebKitStopsListingIt() async throws {
        let context = try makeContext()
        let jar = store(for: UUID().uuidString)
        MiniAppSessionStorePurgeQueue.note(jar)
        MiniAppSessionStorePurgeQueue.recordAttempt(jar, succeeded: true)
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)

        let log = RemovalLog()
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context, status: status, grants: [:],
            index: fakeIndex([], removed: log), revoke: log.revoke
        )

        XCTAssertEqual(outcome.stores, .swept(reaped: 0, kept: 0, deferred: 0, residual: 0))
        XCTAssertTrue(MiniAppSessionStorePurgeQueue.isEmpty,
                      "nothing on disk means nothing owed — otherwise WebKit is brought up at "
                      + "every launch for a jar that is not there")
        // And with the queue empty the pass goes back to costing nothing.
        let second = await MiniAppSessionStoreSweep.run(
            context: context, status: status, grants: [:],
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: { XCTFail("nothing owed and nothing granted"); return [] },
                remove: { _ in true }
            ),
            revoke: log.revoke
        )
        XCTAssertEqual(second.stores, .skippedNoGrants)
    }

    /// The queue must never outrank the ownership check. A record can come back
    /// — an iCloud restore, a CloudKit record resurrected on another device —
    /// and then the jar it names holds a LIVE user's logins again. Bias: keep.
    func testAQueuedPurgeWhoseRecordCameBackIsForgottenNotDeleted() async throws {
        let context = try makeContext()
        let restored = MiniApp(name: "Bank", emoji: "🏦", html: "<html>b</html>")
        context.insert(restored)
        try context.save()
        let jar = store(for: restored.id.uuidString)
        MiniAppSessionStorePurgeQueue.note(jar)
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)

        let log = RemovalLog()
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context, status: status, grants: [restored.id.uuidString: .browser],
            index: fakeIndex([jar], removed: log), revoke: log.revoke
        )

        XCTAssertEqual(outcome.stores, .swept(reaped: 0, kept: 1, deferred: 0, residual: 0))
        XCTAssertEqual(log.ids, [], "a live record's logins must survive a stale purge note")
        XCTAssertTrue(MiniAppSessionStorePurgeQueue.isEmpty,
                      "and the note must go, or it would fight the record on every launch")
    }

    /// The delete path itself: the note is durable and it is written BEFORE the
    /// attempt, so a kill between the tap and WebKit's answer still leaves the
    /// app owing the deletion. Asserted synchronously on purpose — that is the
    /// whole point of the ordering.
    func testDeletingAMiniAppQueuesItsJarBeforeWebKitIsEvenAsked() async throws {
        usingRealDataStores()
        let appId = UUID().uuidString
        let removal = MiniAppRunnerView.removeSessionStore(for: appId)
        XCTAssertNotNil(MiniAppSessionStorePurgeQueue.record(for: store(for: appId)),
                        "the jar has to be owed the moment the user taps Löschen")
        // Drained on purpose. The removal is deliberately not awaited by the UI,
        // and WebKit materialises a store directory while serving it — left
        // in flight it lands in the middle of a LATER test's enumeration and
        // shows up there as an extra orphan. (Observed: it made
        // `testTheShippedPathRevokesTheRealGrantAndReapsTheRealJar` report
        // `reaped: 2` on one run in two.)
        _ = await removal.value
    }
}
