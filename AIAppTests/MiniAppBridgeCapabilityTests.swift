import XCTest
import SwiftData
import UserNotifications
@testable import AIApp

/// The `window.aiity` capability bridge: durable per-app storage, consent-
/// gated notification scheduling, and the sweep pass that takes both away
/// when the mini-app is gone.
///
/// Hermetic the way `MiniAppSessionStoreSweepTests` is: everything these
/// features touch is global to the DEVICE — the consent map and the purge
/// queue and the notification ledger in the shared `UserDefaults`, the
/// storage directory in the app container, the process-wide notification
/// center. The defaults keys are snapshot/restored (the
/// `MiniAppConsentTests` pattern), the storage root is redirected to a
/// per-test temp directory via `MiniAppStorage.rootOverride`, and the center
/// sits behind `MiniAppNotificationScheduler.centerOverride` — the
/// `gateOverride` pattern — so no test can mutate the real pending requests.
@MainActor
final class MiniAppBridgeCapabilityTests: XCTestCase {

    private var consentV1: Any?
    private var consentV2: Any?
    private var purgesBeforeTest: [MiniAppSessionStorePurgeQueue.Record] = []
    private var ledgerBeforeTest: [String] = []
    private var storageRoot: URL!

    override func setUp() {
        super.setUp()
        consentV1 = UserDefaults.standard.object(forKey: "miniapp-consent-v1")
        consentV2 = UserDefaults.standard.object(forKey: "miniapp-consent-v2")
        UserDefaults.standard.removeObject(forKey: "miniapp-consent-v1")
        UserDefaults.standard.removeObject(forKey: "miniapp-consent-v2")
        purgesBeforeTest = MiniAppSessionStorePurgeQueue.records()
        MiniAppSessionStorePurgeQueue.removeAll()
        ledgerBeforeTest = MiniAppNotificationScheduler.scheduledAppIds()
        MiniAppNotificationScheduler.replaceScheduledAppIds([])
        storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniapp-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        MiniAppStorage.rootOverride = storageRoot
    }

    override func tearDown() {
        MiniAppStorage.rootOverride = nil
        try? FileManager.default.removeItem(at: storageRoot)
        storageRoot = nil
        MiniAppNotificationScheduler.centerOverride = nil
        MiniAppNotificationScheduler.replaceScheduledAppIds(ledgerBeforeTest)
        ledgerBeforeTest = []
        MiniAppSessionStorePurgeQueue.replaceAll(purgesBeforeTest)
        purgesBeforeTest = []
        UserDefaults.standard.set(consentV1, forKey: "miniapp-consent-v1")
        UserDefaults.standard.set(consentV2, forKey: "miniapp-consent-v2")
        super.tearDown()
    }

    // MARK: - Storage

    func testStorageRoundTripIsReadBackFromDisk() {
        let appId = UUID().uuidString
        XCTAssertNil(MiniAppStorage.item(appId: appId, key: "state"))

        XCTAssertTrue(MiniAppStorage.setItem(appId: appId, key: "state", value: "{\"score\":3}"))
        // Every read goes through the file, so this is the restart path too.
        XCTAssertEqual(MiniAppStorage.item(appId: appId, key: "state"), "{\"score\":3}")
        XCTAssertEqual(MiniAppStorage.storedAppIds(), [appId])

        MiniAppStorage.removeItem(appId: appId, key: "state")
        XCTAssertNil(MiniAppStorage.item(appId: appId, key: "state"))
        XCTAssertEqual(MiniAppStorage.storedAppIds(), [], "an emptied store must not linger as a file")
    }

    func testStorageIsIsolatedPerApp() {
        let a = UUID().uuidString
        let b = "preview-abc123"
        MiniAppStorage.setItem(appId: a, key: "k", value: "from-a")
        MiniAppStorage.setItem(appId: b, key: "k", value: "from-b")

        XCTAssertEqual(MiniAppStorage.item(appId: a, key: "k"), "from-a")
        XCTAssertEqual(MiniAppStorage.item(appId: b, key: "k"), "from-b")

        MiniAppStorage.wipe(appId: a)
        XCTAssertNil(MiniAppStorage.item(appId: a, key: "k"))
        XCTAssertEqual(MiniAppStorage.item(appId: b, key: "k"), "from-b")
    }

    func testStorageRefusesWritesOverTheQuotaAndKeepsExistingData() {
        let appId = UUID().uuidString
        XCTAssertTrue(MiniAppStorage.setItem(appId: appId, key: "small", value: "keep-me"))

        let oversized = String(repeating: "x", count: MiniAppStorage.maxBytesPerApp + 1)
        XCTAssertFalse(MiniAppStorage.setItem(appId: appId, key: "big", value: oversized))
        XCTAssertNil(MiniAppStorage.item(appId: appId, key: "big"))
        XCTAssertEqual(MiniAppStorage.item(appId: appId, key: "small"), "keep-me",
                       "a refused write must leave the file untouched")

        // The cap is per app and TOTAL, not per value: two writes that fit
        // individually must still be refused once their sum does not.
        let half = String(repeating: "y", count: 600_000)
        XCTAssertTrue(MiniAppStorage.setItem(appId: appId, key: "one", value: half))
        XCTAssertFalse(MiniAppStorage.setItem(appId: appId, key: "two", value: half))
        XCTAssertNil(MiniAppStorage.item(appId: appId, key: "two"))
    }

    // MARK: - Consent model

    func testAuxGrantIsIndependentOfTheTierLadder() {
        let appId = "aux-app"
        XCTAssertFalse(MiniAppConsent.auxGranted(appId: appId, .notifications))

        MiniAppConsent.allowAux(appId: appId, .notifications)
        XCTAssertTrue(MiniAppConsent.auxGranted(appId: appId, .notifications))
        // The carrier record is .offline and must never satisfy a tier request.
        XCTAssertEqual(MiniAppConsent.granted(appId: appId), .offline)
        XCTAssertFalse(MiniAppConsent.isAllowed(appId: appId, declared: .network))

        // A later tier grant replaces the record — the aux grant must survive.
        MiniAppConsent.allow(appId: appId, capability: .network, hosts: ["api.example"])
        XCTAssertTrue(MiniAppConsent.auxGranted(appId: appId, .notifications))
        XCTAssertEqual(MiniAppConsent.granted(appId: appId), .network)

        MiniAppConsent.revoke(appId: appId)
        XCTAssertFalse(MiniAppConsent.auxGranted(appId: appId, .notifications))
    }

    // MARK: - Notification scheduling

    /// What one fake center saw. Reference type so the seam's escaping
    /// closures and the assertions read the same log.
    private final class CenterLog {
        var added: [UNNotificationRequest] = []
        var removed: [String] = []
        var authorizationRequests = 0
    }

    private func installCenter(
        gate: NotificationGate.Decision = .post,
        granting: Bool = true,
        pending: [String] = [],
        log: CenterLog
    ) {
        MiniAppNotificationScheduler.centerOverride = MiniAppNotificationScheduler.Center(
            gate: { gate },
            requestAuthorization: { log.authorizationRequests += 1; return granting },
            add: { log.added.append($0) },
            pendingIdentifiers: { pending + log.added.map(\.identifier) },
            removePending: { log.removed.append(contentsOf: $0) }
        )
    }

    func testScheduleAddsAnAppScopedRequestWithRoutingUserInfo() async {
        let log = CenterLog()
        installCenter(log: log)
        let appId = UUID().uuidString
        let now = Date()
        let at = (now.timeIntervalSince1970 + 3600) * 1000

        let result = await MiniAppNotificationScheduler.schedule(
            appId: appId, title: "Gießen", body: "Die Pflanzen warten", at: at, now: now
        )

        XCTAssertEqual(result["ok"] as? Bool, true)
        let request = log.added.first
        XCTAssertEqual(log.added.count, 1)
        XCTAssertEqual(result["id"] as? String, request?.identifier)
        XCTAssertTrue(request?.identifier.hasPrefix("miniapp-\(appId)-") ?? false)
        XCTAssertEqual(
            request?.content.userInfo[MiniAppNotificationScheduler.userInfoAppIdKey] as? String,
            appId,
            "the tap route needs the owning app id in userInfo"
        )
        let trigger = request?.trigger as? UNTimeIntervalNotificationTrigger
        XCTAssertEqual(trigger?.timeInterval ?? 0, 3600, accuracy: 1)
        XCTAssertEqual(MiniAppNotificationScheduler.scheduledAppIds(), [appId],
                       "a successful schedule must arm the sweep's durable ledger")
    }

    func testScheduleAcceptsISO8601Strings() async {
        let log = CenterLog()
        installCenter(log: log)
        let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(120))

        let result = await MiniAppNotificationScheduler.schedule(
            appId: UUID().uuidString, title: "T", body: "B", at: iso
        )
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(log.added.count, 1)
    }

    func testScheduleRejectsPastAndUnparseableDates() async {
        let log = CenterLog()
        installCenter(log: log)
        let appId = UUID().uuidString

        let past = await MiniAppNotificationScheduler.schedule(
            appId: appId, title: "T", body: "B",
            at: (Date().timeIntervalSince1970 - 60) * 1000
        )
        XCTAssertEqual(past["ok"] as? Bool, false)
        XCTAssertEqual(past["error"] as? String, "date_in_past")

        for bad in [nil, "gestern Abend" as Any] as [Any?] {
            let result = await MiniAppNotificationScheduler.schedule(
                appId: appId, title: "T", body: "B", at: bad
            )
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual(result["error"] as? String, "invalid_date")
        }
        XCTAssertEqual(log.added.count, 0)
        XCTAssertEqual(log.authorizationRequests, 0,
                       "an invalid call must never reach the OS permission dialog")
        XCTAssertEqual(MiniAppNotificationScheduler.scheduledAppIds(), [])
    }

    func testScheduleEnforcesTheCapPerAppNotGlobally() async {
        let crowded = UUID().uuidString
        let other = UUID().uuidString
        let full = (0..<MiniAppNotificationScheduler.maxPendingPerApp).map {
            _ in MiniAppNotificationScheduler.identifierPrefix(appId: crowded) + UUID().uuidString
        }
        let log = CenterLog()
        installCenter(pending: full, log: log)
        let at = (Date().timeIntervalSince1970 + 60) * 1000

        let refused = await MiniAppNotificationScheduler.schedule(
            appId: crowded, title: "T", body: "B", at: at
        )
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "limit_exceeded")
        XCTAssertEqual(log.added.count, 0)

        // Another app's eight pending requests are not this app's problem.
        let allowed = await MiniAppNotificationScheduler.schedule(
            appId: other, title: "T", body: "B", at: at
        )
        XCTAssertEqual(allowed["ok"] as? Bool, true)
    }

    func testScheduleKeepsPermissionDeniedShapeWhenRefusedOrNotGranted() async {
        let at = (Date().timeIntervalSince1970 + 60) * 1000

        // Previously denied: no re-prompt, documented shape back.
        let refusedLog = CenterLog()
        installCenter(gate: .refuse, log: refusedLog)
        let refused = await MiniAppNotificationScheduler.schedule(
            appId: UUID().uuidString, title: "T", body: "B", at: at
        )
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["error"] as? String, "permission_denied")
        XCTAssertEqual(refusedLog.authorizationRequests, 0)
        XCTAssertEqual(refusedLog.added.count, 0)

        // First use, user declines the OS dialog: asked exactly once, nothing added.
        let declinedLog = CenterLog()
        installCenter(gate: .ask, granting: false, log: declinedLog)
        let declined = await MiniAppNotificationScheduler.schedule(
            appId: UUID().uuidString, title: "T", body: "B", at: at
        )
        XCTAssertEqual(declined["error"] as? String, "permission_denied")
        XCTAssertEqual(declinedLog.authorizationRequests, 1)
        XCTAssertEqual(declinedLog.added.count, 0)
    }

    func testCancelAllRemovesOnlyThisAppsPendingRequests() async {
        let mine = UUID().uuidString
        let other = UUID().uuidString
        let mineIds = [
            MiniAppNotificationScheduler.identifierPrefix(appId: mine) + UUID().uuidString,
            MiniAppNotificationScheduler.identifierPrefix(appId: mine) + UUID().uuidString,
        ]
        let otherId = MiniAppNotificationScheduler.identifierPrefix(appId: other) + UUID().uuidString
        let log = CenterLog()
        installCenter(pending: mineIds + [otherId, "miniapp-\(UUID().uuidString)"], log: log)
        MiniAppNotificationScheduler.replaceScheduledAppIds([mine, other])

        let cancelled = await MiniAppNotificationScheduler.cancelAll(appId: mine)

        XCTAssertEqual(cancelled, 2)
        XCTAssertEqual(Set(log.removed), Set(mineIds))
        XCTAssertEqual(MiniAppNotificationScheduler.scheduledAppIds(), [other],
                       "cancelAll must settle the ledger for its app and only its app")
    }

    func testIdentifierRoundTripsTheAppIdAndRefusesLegacyShapes() {
        let uuid = UUID().uuidString
        for appId in [uuid, "preview-4f2a9c"] {
            let identifier = MiniAppNotificationScheduler.identifierPrefix(appId: appId) + UUID().uuidString
            XCTAssertEqual(MiniAppNotificationScheduler.appId(fromIdentifier: identifier), appId)
        }
        // The legacy MiniAppNotificationService shape has no app id in it.
        XCTAssertNil(MiniAppNotificationScheduler.appId(fromIdentifier: "miniapp-\(uuid)"))
        XCTAssertNil(MiniAppNotificationScheduler.appId(fromIdentifier: "somethingelse-\(uuid)"))
    }

    // MARK: - Sweep

    /// A deleted mini-app loses its storage file and its pending notifications
    /// on the next pass — through the REAL default seams, made hermetic by
    /// `rootOverride`, `centerOverride` and the replaced ledger. Also pins the
    /// trigger: grants are empty here, so only the storage file / ledger entry
    /// can be what makes the pass run at all.
    func testSweepWipesStorageAndCancelsNotificationsForDeletedApps() async throws {
        let container = try ModelContainer(
            for: MiniApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let alive = MiniApp(name: "Lebt", emoji: "🌱", html: "<html>a</html>")
        context.insert(alive)
        try context.save()
        let gone = UUID()
        let preview = MiniAppConsent.previewId(html: "<html>p</html>")

        MiniAppStorage.setItem(appId: alive.id.uuidString, key: "k", value: "keep")
        MiniAppStorage.setItem(appId: gone.uuidString, key: "k", value: "doomed")
        MiniAppStorage.setItem(appId: preview, key: "k", value: "keep")

        let goneIds = [
            MiniAppNotificationScheduler.identifierPrefix(appId: gone.uuidString) + UUID().uuidString,
            MiniAppNotificationScheduler.identifierPrefix(appId: gone.uuidString) + UUID().uuidString,
        ]
        let aliveId = MiniAppNotificationScheduler.identifierPrefix(appId: alive.id.uuidString) + UUID().uuidString
        let log = CenterLog()
        installCenter(pending: goneIds + [aliveId], log: log)
        MiniAppNotificationScheduler.replaceScheduledAppIds(
            [alive.id.uuidString, gone.uuidString, preview]
        )

        let status = SyncStatus(importWaitTimeout: 0.1) { $0(false) }
        status.report(.localOnly)

        let outcome = await MiniAppSessionStoreSweep.run(
            context: context,
            status: status,
            grants: [:],
            index: MiniAppSessionStoreSweep.StoreIndex(
                identifiers: {
                    XCTFail("no browser grant and nothing owed — WebKit must stay down")
                    return []
                },
                remove: { _ in true }
            ),
            revoke: { _ in XCTFail("no grants exist to revoke") },
            revisionOwners: { [] },
            removeRevisions: { _ in XCTFail("no revisions exist to remove") }
        )

        XCTAssertEqual(outcome.stores, .skippedNoBrowserGrants,
                       "storage/ledger must trigger the pass without reviving the jar half")
        XCTAssertEqual(outcome.wipedStorage, [gone.uuidString])
        XCTAssertEqual(outcome.cancelledNotifications, [gone.uuidString])

        XCTAssertEqual(MiniAppStorage.item(appId: alive.id.uuidString, key: "k"), "keep")
        XCTAssertEqual(MiniAppStorage.item(appId: preview, key: "k"), "keep",
                       "a preview has no record by design — its data stays")
        XCTAssertNil(MiniAppStorage.item(appId: gone.uuidString, key: "k"))

        XCTAssertEqual(Set(log.removed), Set(goneIds),
                       "only the deleted app's pending requests may be cancelled")
        XCTAssertEqual(
            MiniAppNotificationScheduler.scheduledAppIds(),
            [alive.id.uuidString, preview].sorted(),
            "the ledger keeps live and preview owners, forgets the deleted one"
        )
    }
}
