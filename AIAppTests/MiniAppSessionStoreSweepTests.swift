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

    private func fakeIndex(
        _ found: [UUID], removed: RemovalLog
    ) -> MiniAppSessionStoreSweep.StoreIndex {
        MiniAppSessionStoreSweep.StoreIndex(
            identifiers: { removed.events.append("list"); return found },
            remove: {
                removed.ids.append($0)
                removed.events.append("remove")
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

        XCTAssertEqual(outcome.stores, .swept(reaped: 1, kept: 1))
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
                remove: { log.ids.append($0) }
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
                remove: { log.ids.append($0) }
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
        XCTAssertEqual(outcome.stores, .swept(reaped: 1, kept: 0))
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
                remove: { disk.jars.remove($0); first.ids.append($0) }
            ),
            revoke: first.revoke
        )
        for revoked in firstOutcome.revokedGrants { grants.removeValue(forKey: revoked) }
        XCTAssertTrue(disk.jars.isEmpty, "pass one must take the jar with it")

        // Pass two, next launch, reading the grants pass one left behind.
        let second = RemovalLog()
        let secondOutcome = await MiniAppSessionStoreSweep.run(
            context: context, status: status, grants: grants,
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: { XCTFail("no grant left, so no sweep"); return [] },
                remove: { second.ids.append($0) }
            ),
            revoke: second.revoke
        )
        XCTAssertEqual(secondOutcome.stores, .skippedNoGrants)
        XCTAssertEqual(second.events, [])
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
        WebKitRuntime.ensureInitialised()
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

        let context = try makeContext()
        let live = MiniApp(name: "Bank", emoji: "🏦", html: "<html>b</html>")
        live.id = keeper                      // the record the orphan does NOT have
        context.insert(live)
        try context.save()
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
        XCTAssertFalse(onDisk.contains(store(for: orphan.uuidString)),
                       "the jar with no record must be gone")
        if case .swept(let reaped, _) = outcome.stores {
            XCTAssertGreaterThanOrEqual(reaped, 1)
        } else {
            XCTFail("expected a sweep, got \(outcome)")
        }
        XCTAssertEqual(log.revoked, [orphan.uuidString],
                       "the same pass must take the orphan's grant, not only its jar")

        await withCheckedContinuation { continuation in
            WebKitRuntime.ensureInitialised()
            WKWebsiteDataStore.remove(forIdentifier: store(for: keeper.uuidString)) { _ in
                continuation.resume()
            }
        }
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
        WebKitRuntime.ensureInitialised()
        let keeper = UUID()
        let orphan = UUID()
        // Leave the user's real defaults exactly as we found them.
        defer {
            MiniAppConsent.revoke(appId: keeper.uuidString)
            MiniAppConsent.revoke(appId: orphan.uuidString)
        }
        MiniAppConsent.allow(appId: keeper.uuidString, capability: .browser)
        MiniAppConsent.allow(appId: orphan.uuidString, capability: .browser)
        try await writeCookie(into: store(for: keeper.uuidString), name: "keep")
        try await writeCookie(into: store(for: orphan.uuidString), name: "orphan")

        var onDisk = await allIdentifiers()
        guard onDisk.contains(store(for: keeper.uuidString)),
              onDisk.contains(store(for: orphan.uuidString)) else {
            throw XCTSkip("WebKit did not persist the test data stores in this environment")
        }

        let context = try makeContext()
        let live = MiniApp(name: "Bank", emoji: "🏦", html: "<html>b</html>")
        live.id = keeper
        context.insert(live)
        try context.save()
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

        onDisk = await allIdentifiers()
        XCTAssertFalse(onDisk.contains(store(for: orphan.uuidString)),
                       "the jar must be reaped in the SAME pass, not stranded by the revocation")
        XCTAssertTrue(onDisk.contains(store(for: keeper.uuidString)))

        await withCheckedContinuation { continuation in
            WebKitRuntime.ensureInitialised()
            WKWebsiteDataStore.remove(forIdentifier: store(for: keeper.uuidString)) { _ in
                continuation.resume()
            }
        }
    }

    /// A persistent store only reaches disk once something is written to it.
    private func writeCookie(into identifier: UUID, name: String) async throws {
        let dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "example.com", .path: "/", .name: name, .value: "1",
            .expires: Date().addingTimeInterval(3600),
        ]))
        await dataStore.httpCookieStore.setCookie(cookie)
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
}
