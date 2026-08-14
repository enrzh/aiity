import XCTest
import SwiftData
@testable import AIApp

/// Revision history on a redirected base directory, plus the sweep's third
/// reconciled resource. Hermeticity follows `MiniAppSessionStoreSweepTests`:
/// every test gets its own unique temp directory via the
/// `MiniAppRevisionStore.baseDirectory` seam, and — because `run` reads the
/// REAL consent map and purge queue out of the shared `UserDefaults` — both
/// are snapshotted in `setUp` and put back in `tearDown`, which also removes
/// the temp directory on failure (an inline cleanup at the end of a test body
/// could not).
@MainActor
final class MiniAppRevisionStoreTests: XCTestCase {

    private var baseBeforeTest: URL!
    private var tempDirectory: URL!
    private var grantsBeforeTest: [String: MiniAppCapability] = [:]
    private var purgesBeforeTest: [MiniAppSessionStorePurgeQueue.Record] = []

    override func setUp() async throws {
        try await super.setUp()
        baseBeforeTest = MiniAppRevisionStore.baseDirectory
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("revisions-\(UUID().uuidString)", isDirectory: true)
        MiniAppRevisionStore.baseDirectory = tempDirectory
        grantsBeforeTest = MiniAppConsent.grants()
        for appId in grantsBeforeTest.keys { MiniAppConsent.revoke(appId: appId) }
        purgesBeforeTest = MiniAppSessionStorePurgeQueue.records()
        MiniAppSessionStorePurgeQueue.removeAll()
    }

    override func tearDown() async throws {
        MiniAppRevisionStore.baseDirectory = baseBeforeTest
        try? FileManager.default.removeItem(at: tempDirectory)
        for appId in MiniAppConsent.grants().keys { MiniAppConsent.revoke(appId: appId) }
        for (appId, capability) in grantsBeforeTest {
            MiniAppConsent.allow(appId: appId, capability: capability)
        }
        grantsBeforeTest = [:]
        MiniAppSessionStorePurgeQueue.replaceAll(purgesBeforeTest)
        purgesBeforeTest = []
        try await super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MiniApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    // MARK: - Record / read back

    func testRecordAndReadBackNewestFirst() {
        let appId = UUID()
        MiniAppRevisionStore.record(appId: appId, html: "<html>v1</html>", at: Date(timeIntervalSince1970: 100))
        MiniAppRevisionStore.record(appId: appId, html: "<html>v2</html>", at: Date(timeIntervalSince1970: 200))

        let revisions = MiniAppRevisionStore.revisions(appId: appId)
        XCTAssertEqual(revisions.count, 2)
        XCTAssertEqual(MiniAppRevisionStore.html(appId: appId, revision: revisions[0]), "<html>v2</html>")
        XCTAssertEqual(MiniAppRevisionStore.html(appId: appId, revision: revisions[1]), "<html>v1</html>")
        XCTAssertEqual(revisions[0].bytes, Data("<html>v2</html>".utf8).count)
    }

    func testTwoRevisionsInTheSameSecondBothSurvive() {
        let appId = UUID()
        let instant = Date(timeIntervalSince1970: 300)
        MiniAppRevisionStore.record(appId: appId, html: "<html>a</html>", at: instant)
        MiniAppRevisionStore.record(appId: appId, html: "<html>b</html>", at: instant)

        let revisions = MiniAppRevisionStore.revisions(appId: appId)
        XCTAssertEqual(revisions.count, 2)
        XCTAssertNotEqual(revisions[0].fileName, revisions[1].fileName,
                          "same-second saves must not overwrite each other")
        XCTAssertEqual(MiniAppRevisionStore.html(appId: appId, revision: revisions[0]), "<html>b</html>",
                       "insertion order stands in for a date the stamp cannot distinguish")
    }

    func testEmptyHTMLIsNotRecorded() {
        let appId = UUID()
        MiniAppRevisionStore.record(appId: appId, html: "")
        MiniAppRevisionStore.record(appId: appId, html: "  \n ")
        XCTAssertTrue(MiniAppRevisionStore.revisions(appId: appId).isEmpty)
    }

    // MARK: - Prune

    func testPruneKeepsOnlyTheNewestTwentyOnDiskToo() throws {
        let appId = UUID()
        for i in 1...25 {
            MiniAppRevisionStore.record(
                appId: appId,
                html: "<html>v\(i)</html>",
                at: Date(timeIntervalSince1970: TimeInterval(i))
            )
        }

        let revisions = MiniAppRevisionStore.revisions(appId: appId)
        XCTAssertEqual(revisions.count, MiniAppRevisionStore.maxRevisionsPerApp)
        XCTAssertEqual(MiniAppRevisionStore.html(appId: appId, revision: revisions[0]), "<html>v25</html>")
        XCTAssertEqual(MiniAppRevisionStore.html(appId: appId, revision: revisions[19]), "<html>v6</html>")

        // The prune must delete the FILES, not just the index entries — an
        // index-only prune would grow the directory forever.
        let onDisk = try FileManager.default.contentsOfDirectory(
            atPath: MiniAppRevisionStore.directory(for: appId).path
        )
        XCTAssertEqual(onDisk.filter { $0.hasSuffix(".html") }.count,
                       MiniAppRevisionStore.maxRevisionsPerApp)
    }

    // MARK: - Restore round-trip

    /// The UI's restore sequence, at store level: the choke point records v1
    /// before v2 replaces it, and the restore records v2 before going back to
    /// v1 — after which BOTH states are revisions and nothing was ever lost.
    func testRestoreRoundTripLosesNoState() {
        let appId = UUID()
        MiniAppRevisionStore.record(appId: appId, html: "<html>v1</html>", at: Date(timeIntervalSince1970: 100))
        let v1 = MiniAppRevisionStore.revisions(appId: appId)[0]
        let restored = MiniAppRevisionStore.html(appId: appId, revision: v1)
        XCTAssertEqual(restored, "<html>v1</html>")
        MiniAppRevisionStore.record(appId: appId, html: "<html>v2</html>", at: Date(timeIntervalSince1970: 200))

        let all = MiniAppRevisionStore.revisions(appId: appId)
            .compactMap { MiniAppRevisionStore.html(appId: appId, revision: $0) }
        XCTAssertEqual(all, ["<html>v2</html>", "<html>v1</html>"])
    }

    // MARK: - Removal / enumeration

    func testRemoveAllDeletesTheWholeDirectory() {
        let appId = UUID()
        MiniAppRevisionStore.record(appId: appId, html: "<html>x</html>")
        XCTAssertEqual(MiniAppRevisionStore.revisionAppIds(), [appId])

        MiniAppRevisionStore.removeAll(appId: appId)
        XCTAssertTrue(MiniAppRevisionStore.revisions(appId: appId).isEmpty)
        XCTAssertTrue(MiniAppRevisionStore.revisionAppIds().isEmpty)
    }

    func testRevisionAppIdsIgnoresForeignDirectories() throws {
        let appId = UUID()
        MiniAppRevisionStore.record(appId: appId, html: "<html>x</html>")
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("kein-uuid", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(MiniAppRevisionStore.revisionAppIds(), [appId],
                       "whatever a non-UUID directory is, this store did not create it")
    }

    // MARK: - Sweep: revisions as the third reconciled resource

    func testStaleRevisionIdsRequireTheSameGateAsTheOtherHalves() {
        let orphan = UUID()
        XCTAssertEqual(
            MiniAppSessionStoreSweep.staleRevisionAppIds(
                revisionOwners: [orphan], liveAppIds: [],
                mode: .synced, initialImportComplete: false
            ),
            [],
            "an unimported record must not look like a deleted one"
        )
        for mode in [SyncStatus.Mode.recovered, .inMemory] {
            XCTAssertEqual(
                MiniAppSessionStoreSweep.staleRevisionAppIds(
                    revisionOwners: [orphan], liveAppIds: [],
                    mode: mode, initialImportComplete: true
                ),
                []
            )
        }
    }

    func testALiveRecordProtectsItsRevisions() {
        let app = UUID()
        XCTAssertEqual(
            MiniAppSessionStoreSweep.staleRevisionAppIds(
                revisionOwners: [app], liveAppIds: [app],
                mode: .localOnly, initialImportComplete: true
            ),
            []
        )
    }

    /// End to end: a mirror-deleted app's history goes, the live app's stays —
    /// and with no browser grant anywhere, WebKit is never brought up for it.
    func testSweepRemovesOnlyTheOrphanedRevisionDirectory() async throws {
        let context = try makeContext()
        let live = MiniApp(name: "Lebt", emoji: "✅", html: "<html>l</html>")
        context.insert(live)
        try context.save()
        let gone = UUID()
        MiniAppRevisionStore.record(appId: live.id, html: "<html>l1</html>")
        MiniAppRevisionStore.record(appId: gone, html: "<html>g1</html>")

        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: [:],
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: {
                    XCTFail("no browser grant — revisions alone must not bring WebKit up")
                    return []
                },
                remove: { _ in true }
            ),
            // The other reconciled resources read real device state by
            // default — pinned empty so only revisions drive this test.
            storageOwners: { [] },
            wipeStorage: { _ in },
            notificationOwners: { [] },
            cancelNotifications: { _ in }
        )

        XCTAssertEqual(outcome.stores, .skippedNoBrowserGrants)
        XCTAssertEqual(outcome.removedRevisions, [gone])
        XCTAssertEqual(MiniAppRevisionStore.revisionAppIds(), [live.id])
        XCTAssertEqual(MiniAppRevisionStore.revisions(appId: live.id).count, 1,
                       "the live app's history is untouched")
    }

    /// Nothing on disk, nothing granted, nothing owed: the pass must still
    /// exit at the cheap gate — revisions widen the gate, they must not break
    /// its cheap-exit property.
    func testSweepStillSkipsEntirelyWithNoRevisionsAnywhere() async throws {
        let context = try makeContext()
        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)
        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: [:],
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: { XCTFail("nothing to sweep"); return [] },
                remove: { _ in true }
            ),
            records: { _ in XCTFail("must not even read the library"); return [] },
            storageOwners: { [] },
            wipeStorage: { _ in },
            notificationOwners: { [] },
            cancelNotifications: { _ in }
        )
        XCTAssertEqual(outcome, MiniAppSessionStoreSweep.Outcome(stores: .skippedNoGrants))
    }
}
