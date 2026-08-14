import CoreSpotlight
import SwiftData
import XCTest
@testable import AIApp

/// The system-surface presence of mini-apps: the Spotlight index, the
/// Home-Screen widget's pin, and the deep link between them.
///
/// Hermetic the way the neighbouring suites are: the pin store is pointed at a
/// throwaway defaults suite (never the real App Group — the unit host runs in
/// the app's own container), and every Spotlight call goes through
/// `MiniAppSpotlightIndex`'s seams, which are snapshotted and restored around
/// each test — touching the REAL system index from a test would leave junk
/// entries on the developer's device. `WidgetCenter.reloadTimelines` is left
/// real on purpose: with no widget installed it is a no-op with no observable
/// state to leak.
@MainActor
final class MiniAppSystemSurfaceTests: XCTestCase {

    private var testSuiteName = ""
    private var previousSuiteName = ""
    private var previousSystemIndex: MiniAppSpotlightIndex.Index!
    private var previousRecords: (@MainActor (ModelContext) -> [MiniAppSpotlightIndex.App]?)!
    private var previousPinned: (@MainActor () -> PinnedMiniApp?)!
    private var previousStorePin: (@MainActor (PinnedMiniApp) -> Void)!
    private var previousClearPin: (@MainActor () -> Void)!
    /// The durable purge queue as this test found it — the sweep-level test
    /// drives the real `MiniAppSessionStoreSweep.run`, which reads and prunes
    /// the queue in the shared `UserDefaults` (same reason the sweep suite
    /// snapshots it).
    private var purgesBeforeTest: [MiniAppSessionStorePurgeQueue.Record] = []

    override func setUp() async throws {
        try await super.setUp()
        previousSuiteName = PinnedMiniAppStore.suiteName
        testSuiteName = "test-pinned-miniapp-\(UUID().uuidString)"
        PinnedMiniAppStore.suiteName = testSuiteName
        previousSystemIndex = MiniAppSpotlightIndex.systemIndex
        previousRecords = MiniAppSpotlightIndex.records
        previousPinned = MiniAppSpotlightIndex.pinned
        previousStorePin = MiniAppSpotlightIndex.storePin
        previousClearPin = MiniAppSpotlightIndex.clearPin
        purgesBeforeTest = MiniAppSessionStorePurgeQueue.records()
        MiniAppSessionStorePurgeQueue.removeAll()
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: testSuiteName)?.removePersistentDomain(forName: testSuiteName)
        PinnedMiniAppStore.suiteName = previousSuiteName
        MiniAppSpotlightIndex.systemIndex = previousSystemIndex
        MiniAppSpotlightIndex.records = previousRecords
        MiniAppSpotlightIndex.pinned = previousPinned
        MiniAppSpotlightIndex.storePin = previousStorePin
        MiniAppSpotlightIndex.clearPin = previousClearPin
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

    /// Records every Spotlight and pin effect on ONE timeline, so the order
    /// between the domain reset and the reindex is assertable.
    @MainActor private final class SurfaceLog {
        var events: [String] = []
        var indexedIds: [String] = []
        var storedPins: [PinnedMiniApp] = []
        var clearedPins = 0
    }

    private func fakeSystemIndex(_ log: SurfaceLog) -> MiniAppSpotlightIndex.Index {
        MiniAppSpotlightIndex.Index(
            deleteDomain: { domain in log.events.append("delete \(domain)") },
            indexItems: { items in
                log.events.append("index \(items.count)")
                log.indexedIds.append(contentsOf: items.map(\.uniqueIdentifier))
            }
        )
    }

    /// Wires all pin seams to the log. The store seams stay real only in the
    /// round-trip tests below, which is the point of each half.
    private func seamPins(
        _ log: SurfaceLog, pinned: PinnedMiniApp?
    ) {
        MiniAppSpotlightIndex.pinned = { pinned }
        MiniAppSpotlightIndex.storePin = { log.storedPins.append($0); log.events.append("store-pin") }
        MiniAppSpotlightIndex.clearPin = { log.clearedPins += 1; log.events.append("clear-pin") }
    }

    // MARK: - Pin store round trip

    func testAPinRoundTripsThroughTheStore() {
        XCTAssertNil(PinnedMiniAppStore.load(), "a fresh suite has no pin")
        let pin = PinnedMiniApp(id: UUID(), name: "Zähler", emoji: "🔢", iconSymbol: nil)
        PinnedMiniAppStore.pin(pin)
        XCTAssertEqual(PinnedMiniAppStore.load(), pin)

        // Pinning again replaces — there is exactly one pinned app.
        let successor = PinnedMiniApp(id: UUID(), name: "Timer", emoji: "⏱", iconSymbol: "timer")
        PinnedMiniAppStore.pin(successor)
        XCTAssertEqual(PinnedMiniAppStore.load(), successor)

        PinnedMiniAppStore.clear()
        XCTAssertNil(PinnedMiniAppStore.load())
    }

    func testPinningALibraryRecordSnapshotsItsDisplayFields() {
        let app = MiniApp(name: "Einkauf", emoji: "🛒", html: "<html>x</html>", iconSymbol: "cart")
        PinnedMiniAppStore.pin(app: app)
        XCTAssertEqual(
            PinnedMiniAppStore.load(),
            PinnedMiniApp(id: app.id, name: "Einkauf", emoji: "🛒", iconSymbol: "cart")
        )
    }

    // MARK: - Deep link

    func testTheWidgetDeepLinkRoundTrips() throws {
        let id = UUID()
        let url = try XCTUnwrap(MiniAppDeepLink.url(for: id))
        XCTAssertEqual(url.scheme, "aiity")
        XCTAssertEqual(url.host, "miniapp")
        XCTAssertEqual(MiniAppDeepLink.miniAppId(from: url), id)
    }

    /// The `aiity://` scheme belongs to OAuth callbacks first — nothing that
    /// is not exactly `aiity://miniapp/<uuid>` may parse as a mini-app link,
    /// or the root's handler would swallow URLs it does not own.
    func testForeignURLsAreNotMiniAppLinks() {
        let foreign = [
            "aiity://oauth-callback?code=abc",
            "aiity://miniapp",
            "aiity://miniapp/not-a-uuid",
            "aiity://miniapp/\(UUID().uuidString)/extra",
            "aiapp://miniapp/\(UUID().uuidString)",
            "https://miniapp/\(UUID().uuidString)",
        ]
        for raw in foreign {
            guard let url = URL(string: raw) else { continue }
            XCTAssertNil(MiniAppDeepLink.miniAppId(from: url), raw)
        }
    }

    // MARK: - Searchable item construction

    func testASearchableItemCarriesIdentityDomainAndKeywords() {
        let id = UUID()
        let item = MiniAppSpotlightIndex.item(
            for: .init(id: id, name: "Einkaufs Liste", emoji: "🛒", symbol: nil)
        )
        XCTAssertEqual(item.uniqueIdentifier, id.uuidString,
                       "activation resolves the record by exactly this string")
        XCTAssertEqual(item.domainIdentifier, MiniAppSpotlightIndex.domainIdentifier)
        XCTAssertEqual(item.attributeSet.title, "Einkaufs Liste")
        XCTAssertEqual(item.attributeSet.keywords, ["Einkaufs", "Liste", "🛒"])
        let description = item.attributeSet.contentDescription ?? ""
        XCTAssertFalse(description.isEmpty, "the result needs its one fixed subtitle line")
    }

    func testAnUnnamedAppStillGetsATitleAndNoEmptyKeywords() {
        let item = MiniAppSpotlightIndex.item(
            for: .init(id: UUID(), name: "", emoji: "✨", symbol: nil)
        )
        XCTAssertFalse((item.attributeSet.title ?? "").isEmpty)
        XCTAssertEqual(item.attributeSet.keywords, ["✨"])
    }

    // MARK: - Reconcile

    func testReconcileResetsTheDomainThenReindexesEveryLiveRecord() async throws {
        let context = try makeContext()
        let counter = MiniApp(name: "Zähler", emoji: "🔢", html: "<html>a</html>")
        let timer = MiniApp(name: "Timer", emoji: "⏱", html: "<html>b</html>")
        context.insert(counter)
        context.insert(timer)
        try context.save()
        let log = SurfaceLog()
        MiniAppSpotlightIndex.systemIndex = fakeSystemIndex(log)
        seamPins(log, pinned: nil)

        let outcome = await MiniAppSpotlightIndex.reconcile(context: context)

        XCTAssertEqual(outcome, MiniAppSpotlightIndex.Outcome(indexed: 2))
        XCTAssertEqual(log.events, ["delete miniapps", "index 2"],
                       "the domain reset must come first or a mirrored delete lingers")
        XCTAssertEqual(Set(log.indexedIds), [counter.id.uuidString, timer.id.uuidString])
    }

    func testReconcileClearsAPinWhoseRecordIsGone() async throws {
        let context = try makeContext()
        let survivor = MiniApp(name: "Bleibt", emoji: "🌱", html: "<html>x</html>")
        context.insert(survivor)
        try context.save()
        let log = SurfaceLog()
        MiniAppSpotlightIndex.systemIndex = fakeSystemIndex(log)
        // Pinned on this device, deleted on another — the mirrored delete no
        // local code path ever observes.
        seamPins(log, pinned: PinnedMiniApp(id: UUID(), name: "Weg", emoji: "👻", iconSymbol: nil))

        let outcome = await MiniAppSpotlightIndex.reconcile(context: context)

        XCTAssertTrue(outcome.clearedStalePin)
        XCTAssertEqual(log.clearedPins, 1)
        XCTAssertEqual(log.storedPins, [], "a gone record is cleared, never rewritten")
    }

    func testReconcileRefreshesARenamedPinInPlace() async throws {
        let context = try makeContext()
        let app = MiniApp(name: "Neuer Name", emoji: "🆕", html: "<html>x</html>")
        context.insert(app)
        try context.save()
        let log = SurfaceLog()
        MiniAppSpotlightIndex.systemIndex = fakeSystemIndex(log)
        // Pinned before the rename: same id, stale display fields.
        seamPins(log, pinned: PinnedMiniApp(id: app.id, name: "Alter Name", emoji: "🕰", iconSymbol: nil))

        let outcome = await MiniAppSpotlightIndex.reconcile(context: context)

        XCTAssertTrue(outcome.refreshedPin)
        XCTAssertEqual(
            log.storedPins,
            [PinnedMiniApp(id: app.id, name: "Neuer Name", emoji: "🆕", iconSymbol: nil)]
        )
        XCTAssertEqual(log.clearedPins, 0)
    }

    func testReconcileLeavesAnUnchangedPinAlone() async throws {
        let context = try makeContext()
        let app = MiniApp(name: "Stabil", emoji: "🪨", html: "<html>x</html>")
        context.insert(app)
        try context.save()
        let log = SurfaceLog()
        MiniAppSpotlightIndex.systemIndex = fakeSystemIndex(log)
        seamPins(log, pinned: PinnedMiniApp(id: app.id, name: "Stabil", emoji: "🪨", iconSymbol: nil))

        let outcome = await MiniAppSpotlightIndex.reconcile(context: context)

        XCTAssertEqual(outcome, MiniAppSpotlightIndex.Outcome(indexed: 1),
                       "no pin writes means no widget reload churn")
        XCTAssertEqual(log.storedPins, [])
        XCTAssertEqual(log.clearedPins, 0)
    }

    /// Unreadable is NOT empty — wiping the domain (and the pin) over a
    /// transient fetch error is the mistake the session-store sweep refuses to
    /// make, and this pass shares the bias.
    func testAnUnreadableLibraryReconcilesNothing() async throws {
        let context = try makeContext()
        let log = SurfaceLog()
        MiniAppSpotlightIndex.systemIndex = fakeSystemIndex(log)
        MiniAppSpotlightIndex.records = { _ in nil }
        seamPins(log, pinned: PinnedMiniApp(id: UUID(), name: "Weg?", emoji: "❓", iconSymbol: nil))

        let outcome = await MiniAppSpotlightIndex.reconcile(context: context)

        XCTAssertEqual(outcome, MiniAppSpotlightIndex.Outcome(skippedUnreadableLibrary: true))
        XCTAssertEqual(log.events, [], "no delete, no index, no pin action")
    }

    // MARK: - Through the sweep

    /// The launch pass that already reconciles jars, grants, revisions,
    /// storage and notifications also squares the system surfaces: deleted
    /// apps leave the Spotlight index and a stale pin falls back to the
    /// widget's empty state. Every other resource is injected inert so this
    /// asserts only the composition, not their behaviour.
    func testTheSweepPassClearsAStalePinAndDeindexesDeletedApps() async throws {
        let context = try makeContext()
        let survivor = MiniApp(name: "Bleibt", emoji: "🌱", html: "<html>x</html>")
        context.insert(survivor)
        try context.save()
        let log = SurfaceLog()
        MiniAppSpotlightIndex.systemIndex = fakeSystemIndex(log)
        seamPins(log, pinned: PinnedMiniApp(id: UUID(), name: "Weg", emoji: "👻", iconSymbol: nil))

        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)
        let gone = UUID()
        _ = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            // Non-empty so the pass runs at all; `.network` so WebKit stays
            // out of it entirely.
            grants: [gone.uuidString: .network],
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: { [] },
                remove: { _ in true }
            ),
            revoke: { _ in },
            revisionOwners: { [] },
            removeRevisions: { _ in },
            storageOwners: { [] },
            wipeStorage: { _ in },
            notificationOwners: { [] },
            cancelNotifications: { _ in }
        )

        XCTAssertEqual(log.events.prefix(2), ["delete miniapps", "index 1"])
        XCTAssertEqual(log.indexedIds, [survivor.id.uuidString])
        XCTAssertEqual(log.clearedPins, 1, "the pinned app was mirror-deleted — the widget must fall back")
    }
}
