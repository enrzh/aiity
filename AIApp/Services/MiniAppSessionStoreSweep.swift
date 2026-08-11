import Foundation
import SwiftData
import WebKit

/// The one owner of "reconcile the state a mini-app leaves OUTSIDE its record
/// against the records that are actually still live". Two things outlive a
/// `MiniApp`: its persistent cookie jar on disk, and its consent grant in
/// `UserDefaults`. Both are swept here, in one pass, in a fixed order (see
/// *Ordering* below). Do not grow a second caller for either half.
///
/// **The leak (jars).** A browser-tier mini-app gets its own persistent
/// `WKWebsiteDataStore` (`MiniAppRunnerView.makeUIView`) so the user stays
/// logged in to the site it opens — REAL logins on disk. The only deleter is
/// `MiniAppRunnerView.removeSessionStore(for:)`, and the only thing that calls
/// it is the delete confirmation in `LibraryView`. `MiniApp` records are
/// CloudKit-mirrored: deleting a mini-app on ANOTHER device makes the local
/// record disappear through mirroring without that alert ever running, so the
/// jar stays behind, owned by nothing, forever. This sweep is the second
/// deleter — the one that catches every disappearance the alert cannot see
/// (mirrored delete, a delete that crashed mid-way, a store whose removal
/// failed silently).
///
/// **The leak (grants).** The same alert is also the ONLY caller of
/// `MiniAppConsent.revoke(appId:)`, so a mirrored delete leaves the app's
/// `.network`/`.browser` grant in `UserDefaults` forever. That one is a
/// privilege escalation, not just litter: if a record with the same UUID ever
/// comes back — a backup restore, a re-import, a CloudKit record resurrected
/// on another device — `MiniAppConsent.isAllowed` finds the stale grant and
/// the app silently regains network or browser capability with no consent
/// alert. The consent system exists precisely to make that impossible, so the
/// grant has to die with the record.
///
/// **Where it runs and why.** Once per launch, from `RootView`, on the main
/// actor, after the initial CloudKit import has settled. Deliberately NOT in
/// `BackgroundWorkCoordinator.handleMaintenance`:
///
///  * That task opens no `ModelContainer` on purpose (see `BackgroundWork`),
///    and the only record list available there is `MiniAppIndex` — a snapshot
///    capped at 200 entries and knowingly stale. Using it as the allow-list
///    would delete the cookie jar of app number 201. The allow-list has to
///    come from the real store, which only the running app has open.
///  * WebKit's class APIs are main-thread-only and need WebKit initialised in
///    the process (`WebKitRuntime`); bringing WebKit up inside a background
///    processing task to enumerate directories is strictly worse than doing it
///    in a live app that has the records at hand.
///  * The event that creates the leak — a mirrored delete arriving — is
///    observed in-app anyway, so a launch-time sweep follows it closely
///    enough. A jar surviving until the next cold launch is not a new risk.
///
/// **Ordering — jars FIRST, grants SECOND, in ONE pass. Do not reorder and do
/// not split into two callers.** The cheapest gate on the jar sweep is
/// `grants.values.contains(.browser)`: with no browser grant no persistent
/// store can ever have been created, so the sweep skips and WebKit stays out
/// of the launch path entirely. That gate reads the *same map* the grant
/// cleanup deletes from. Revoke first — or from an earlier, separate caller —
/// and a mirror-deleted app's `.browser` grant is gone before the jar sweep is
/// asked whether to run; the sweep then sees no browser grant, skips, and the
/// orphaned cookie jar (real site logins) stays on disk **forever**, because
/// no later launch will see a browser grant either. So both halves share one
/// pass over one snapshot of `grants`, with the jar work strictly ahead of the
/// revocation. Pinned by `testTheOrphanedJarIsReapedBeforeItsGrantIsRevoked`
/// and `testTheSecondPassAfterRevocationHasNoJarLeftToStrand`.
///
/// **Removals fail, and the failure is the normal case.** WebKit refuses to
/// delete a data store the CURRENT process has opened
/// (`WKWebSiteDataStore Code=1 "Failed to delete files on disk"`), which is
/// exactly the shape of "open a browser mini-app, then delete it" — one launch,
/// one process. A fresh process deletes the same store without complaint. So
/// every removal here reports whether WebKit accepted it, anything unaccepted is
/// written to `MiniAppSessionStorePurgeQueue` (durable) and retried by the next
/// launch's pass, and `.swept(reaped:)` counts only what actually went. That
/// queue is also a THIRD trigger for this pass: an entry in it makes the store
/// half run even when no `.browser` grant is left — without that, a jar whose
/// grant was revoked in the same breath as the failed removal would be
/// unreachable forever.
///
/// **The residual rule.** A removal WebKit *accepts* still leaves a stub
/// directory behind (`…/WebsiteDataStore/<uuid>/ResourceLoadStatistics`) that a
/// LATER process enumerates as a data store again. It has no owner, so it would
/// be doomed again on every launch and reported as a freshly reaped cookie jar
/// every time — a count that never settles, about data that is already gone. So
/// an accepted removal does not forget the identifier, it *tombstones* it
/// (`.residual`): the next pass sweeps it once more so the stub goes, counts it
/// as `residual` rather than `reaped` or `kept`, and forgets it entirely on the
/// first launch that no longer enumerates it. The price is exactly one
/// confirming enumeration after a reap — the launch after the last browser
/// mini-app is deleted still brings WebKit up, once, and then never again.
/// Pinned by `testAnIdentifierAlreadyRemovedOnceCountsAsResidualNotAsAReap`,
/// `testAResidualIsForgottenOnceWebKitStopsListingIt` and the second pass of
/// `testTheSecondPassAfterRevocationHasNoJarLeftToStrand`.
///
/// **Bias: keep.** Every ambiguous case leaves the jar — and the grant — alone.
/// Deleting a live user's site logins is unrecoverable and wrongly revoking is
/// at least a re-prompt; a stale jar living one more cycle is neither. That is
/// why an unreadable library, a store that was recovered/relocated this launch,
/// and an unsettled first import all skip the pass entirely. An unreadable
/// library in particular is never read as "no records exist": that reading
/// would reap every jar and revoke every grant the user has.
@MainActor
enum MiniAppSessionStoreSweep {

    /// What one pass decided, in both halves. Returned rather than only logged
    /// so every refusal is assertable in a test.
    struct Outcome: Equatable {
        /// What happened to the cookie jars on disk.
        var stores: StoreOutcome
        /// Consent grants revoked this pass, sorted. Empty on every skip, and
        /// empty whenever every grant still has a live record behind it. Note
        /// this can be non-empty while `stores` is `.skippedNoBrowserGrants`:
        /// a `.network` grant leaves no jar but still leaks privilege.
        var revokedGrants: [String] = []
    }

    /// What one sweep of the cookie jars decided.
    enum StoreOutcome: Equatable {
        /// The user has never granted ANY capability to ANY mini-app AND
        /// nothing is owed to the purge queue, so there is no jar to reap and no
        /// grant to revoke. The cheap exit that keeps the whole pass — and
        /// WebKit — out of most launches.
        case skippedNoGrants
        /// The store this launch opened cannot vouch for the record set:
        /// `.recovered` (the old store was moved aside, so the library looks
        /// empty while CloudKit still holds the records and will re-import
        /// them on a later launch) or `.inMemory` (no records at all).
        case skippedUnsafeStorageMode
        /// Syncing, but the first CloudKit import has not settled — records
        /// may still be on their way in.
        case skippedImportUnsettled
        /// The user has never granted browser tier to anything and nothing is
        /// owed to the purge queue, so no persistent store can exist. Costs
        /// nothing and, crucially, keeps WebKit out of the launch path for
        /// everyone else. The grant half of the pass still ran.
        case skippedNoBrowserGrants
        /// The record fetch failed. An empty "live" set here would reap every
        /// jar and revoke every grant the user has — refusing is the only safe
        /// reading (same shape as `BackgroundWorkCoordinator.sweepMedia`'s
        /// unreadable-archive case).
        case skippedUnreadableLibrary
        /// What the pass actually achieved. The four counts partition every
        /// identifier WebKit enumerated — `reaped + deferred + residual + kept
        /// == found` — and none of them is a claim the pass cannot back up:
        ///
        ///  * `reaped` — a jar with no live owner whose removal WebKit
        ///    **accepted** this pass. Only these are gone.
        ///  * `kept` — enumerated and owned by something live. Untouched.
        ///  * `deferred` — a jar with no live owner whose removal WebKit
        ///    **refused** (almost always: this process opened it). Still on
        ///    disk, still holding the site's logins, written to
        ///    `MiniAppSessionStorePurgeQueue` and retried next launch. This is
        ///    the count that used to be reported as `reaped`.
        ///  * `residual` — an identifier a PREVIOUS pass already removed
        ///    successfully and that the enumeration still lists: WebKit's own
        ///    leftover metadata directory, not a cookie jar. Removed again
        ///    best-effort, and counted apart so it can neither be mistaken for
        ///    a fresh orphan nor inflate `reaped` on every launch.
        case swept(reaped: Int, kept: Int, deferred: Int, residual: Int)
    }

    // MARK: - Pure policy

    /// Whether the record set this launch can see is the whole truth about
    /// which mini-apps exist.
    ///
    /// `.synced` — only once the initial import has settled. Before that a
    /// missing record means "not here YET", and reaping on it would delete the
    /// logins of an app that is about to arrive.
    /// `.localOnly` — yes, immediately: nothing remote is coming, this device's
    /// file is the whole library. (`SyncStatus` already reports
    /// `initialImportComplete == true` for this mode for exactly that reason.)
    /// `.recovered` / `.inMemory` — never: the visible record set is empty or
    /// unrepresentative through no fault of the user's, and the jars on disk
    /// belong to apps that still exist elsewhere.
    static func mayCompare(mode: SyncStatus.Mode, initialImportComplete: Bool) -> Bool {
        switch mode {
        case .synced: return initialImportComplete
        case .localOnly: return true
        case .recovered, .inMemory: return false
        }
    }

    /// Every store identifier a live owner can still reach, built FORWARD.
    ///
    /// `MiniAppRunnerView.sessionStoreID(for:)` derives the identifier from an
    /// app id (`StableIdentifier`), and a chat preview is keyed by a hash of
    /// its HTML — so an identifier cannot be turned back into an app. The
    /// allow-list is therefore computed from the owners, never inverted.
    ///
    /// Two kinds of owner, matching the two id shapes the runner is ever given
    /// (`LibraryView`/`RootView` pass `app.id.uuidString`, `ChatView` passes
    /// `MiniAppConsent.previewId(html:)`):
    ///
    ///  * **Saved apps** — one identifier per live `MiniApp`. A record that is
    ///    gone is exactly the case this sweep exists for, so a consent grant
    ///    left behind for a deleted app must NOT keep its jar alive; grants are
    ///    only revoked by the local delete path and outlive a mirrored delete.
    ///  * **Chat previews** — the non-UUID consent keys. A preview has no
    ///    record by definition, and it is re-openable from the persisted chat
    ///    transcript at any later launch with the same content hash, so its jar
    ///    stays owned as long as the grant does. Consent membership is a
    ///    complete superset here: the runner only chooses a persistent store
    ///    when `MiniAppConsent.granted(appId:) == .browser`, so no store can
    ///    exist for an id that never appears in the map.
    static func ownedIdentifiers(liveAppIds: [UUID], consentedIds: [String]) -> Set<UUID> {
        var owned = Set(liveAppIds.map { MiniAppRunnerView.sessionStoreID(for: $0.uuidString) })
        for id in consentedIds where UUID(uuidString: id) == nil {
            owned.insert(MiniAppRunnerView.sessionStoreID(for: id))
        }
        return owned
    }

    /// The whole decision, in one testable place: which of the identifiers
    /// actually on disk have no live owner. Order-stable so the log is stable.
    static func plan(
        found: [UUID],
        liveAppIds: [UUID],
        consentedIds: [String],
        mode: SyncStatus.Mode,
        initialImportComplete: Bool
    ) -> [UUID] {
        guard mayCompare(mode: mode, initialImportComplete: initialImportComplete) else { return [] }
        let owned = ownedIdentifiers(liveAppIds: liveAppIds, consentedIds: consentedIds)
        return found.filter { !owned.contains($0) }
    }

    /// The other half of the decision: which consent grants have no live owner
    /// left. Same gate as `plan` — deliberately the same `mayCompare`, not a
    /// second notion of "safe to compare", because both halves are wrong in
    /// exactly the same way when the visible record set is not the truth.
    ///
    /// The rule, and only this rule:
    ///
    ///  * **UUID-shaped key with no live `MiniApp`** — revoke. This is the
    ///    escalation: the grant outlives a mirrored delete and would silently
    ///    re-arm if a record with that UUID ever came back.
    ///  * **UUID-shaped key with a live `MiniApp`** — keep, obviously.
    ///  * **Anything not parseable as a UUID** — keep, always. Those are chat
    ///    previews (`MiniAppConsent.previewId(html:)`), which have no library
    ///    record *by design* and stay re-openable from the persisted
    ///    transcript, so "no record" says nothing about them.
    ///
    /// Sorted so the revocation order — and the log line — is stable.
    static func staleGrantIds(
        grantIds: [String],
        liveAppIds: [UUID],
        mode: SyncStatus.Mode,
        initialImportComplete: Bool
    ) -> [String] {
        guard mayCompare(mode: mode, initialImportComplete: initialImportComplete) else { return [] }
        let live = Set(liveAppIds)
        return grantIds.filter { id in
            guard let uuid = UUID(uuidString: id) else { return false }
            return !live.contains(uuid)
        }.sorted()
    }

    // MARK: - Record seam

    /// The live record ids, or `nil` when the library cannot be read.
    ///
    /// `nil` is emphatically NOT the empty set: collapsing the two is how a
    /// transient store error turns into "every mini-app was deleted", which
    /// would reap every jar and revoke every grant on the device.
    static func liveAppIds(in context: ModelContext) -> [UUID]? {
        guard let apps = try? context.fetch(FetchDescriptor<MiniApp>()) else { return nil }
        return apps.map(\.id)
    }

    // MARK: - WebKit seam

    /// The two `WKWebsiteDataStore` class APIs this needs. Behind a seam
    /// because both are fatal without `WebKitRuntime.ensureInitialised()` and
    /// both touch the real on-disk stores of whatever process runs them — the
    /// ownership logic above must be testable without either.
    struct StoreIndex {
        var identifiers: @MainActor () async -> [UUID]
        /// Answers whether WebKit **accepted** the removal. The error used to be
        /// thrown away here, which is how a refusal ("Failed to delete files on
        /// disk", the answer for any store this process has opened) turned into
        /// a reported reap with the cookies still on disk.
        var remove: @MainActor (UUID) async -> Bool

        static let webKit = StoreIndex(
            identifiers: {
                // Fatal (SIGSEGV) when WebKit has not been initialised in this
                // process, and a launch-time sweep is very often the first
                // WebKit touch there is. See WebKitRuntime.
                WebKitRuntime.ensureInitialised()
                return await withCheckedContinuation { continuation in
                    WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
                }
            },
            remove: { identifier in
                // Same hazard, same guard — this is the other fatal-without-
                // initialisation class API.
                WebKitRuntime.ensureInitialised()
                return await withCheckedContinuation { continuation in
                    WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                        if let error {
                            // The refusal itself, in the breadcrumbs: a purge
                            // that never completes has to be readable in the
                            // diagnostics export, not only inferable from a
                            // count that stopped moving.
                            DiagnosticsRecorder.shared.record(
                                "miniapp",
                                "session store \(identifier.uuidString.prefix(8)) removal refused: "
                                + error.localizedDescription
                            )
                        }
                        continuation.resume(returning: error == nil)
                    }
                }
            }
        )
    }

    // MARK: - Run

    /// Compare the jars on disk AND the consent grants in `UserDefaults`
    /// against the live mini-apps, and delete whichever of them are orphaned.
    /// Safe to call on every launch; does nothing at all when the user has
    /// never granted a capability to anything.
    ///
    /// The two halves run in a fixed order — jars, then grants — for the
    /// reason spelled out under *Ordering* in the type's documentation. They
    /// share one `grants` snapshot so the jar half can never be gated on a map
    /// the grant half has already emptied.
    @discardableResult
    static func run(
        context: ModelContext,
        status: SyncStatus = .shared,
        grants: [String: MiniAppCapability] = MiniAppConsent.grants(),
        index: StoreIndex = .webKit,
        records: @MainActor (ModelContext) -> [UUID]? = MiniAppSessionStoreSweep.liveAppIds(in:),
        revoke: @MainActor (String) -> Void = { MiniAppConsent.revoke(appId: $0) }
    ) async -> Outcome {
        // Everything the previous launches could not finish. Read once, up
        // front: it is both a work list and a reason to run at all.
        let owed = MiniAppSessionStorePurgeQueue.records()

        // Cheapest gate first: nothing was ever granted, so no persistent
        // store was ever created (the runner only picks one for a `.browser`
        // grant) and no grant can have gone stale. WebKit need not come up.
        // An outstanding purge overrides it — that is precisely the state a
        // finished delete leaves behind (record gone, grant revoked, jar not).
        guard !grants.isEmpty || !owed.isEmpty else { return Outcome(stores: .skippedNoGrants) }
        guard mayCompare(mode: status.mode, initialImportComplete: true) else {
            return Outcome(stores: .skippedUnsafeStorageMode)
        }
        // The same "initial import settled" notion the backup restore defers
        // on — successful import, no iCloud account, or the 20 s bound.
        await status.waitUntilInitialImportSettled()
        guard mayCompare(mode: status.mode, initialImportComplete: status.initialImportComplete) else {
            return Outcome(stores: .skippedImportUnsettled)
        }
        guard let live = records(context) else {
            return Outcome(stores: .skippedUnreadableLibrary)
        }

        // ── 1. Cookie jars. MUST stay ahead of step 2: the `.browser` gate
        //       below reads the very grants step 2 deletes, and a jar whose
        //       grant is revoked first is stranded on disk forever.
        var stores: StoreOutcome = .skippedNoBrowserGrants
        if grants.values.contains(.browser) || !owed.isEmpty {
            stores = await sweepStores(
                owed: owed,
                live: live,
                consentedIds: Array(grants.keys),
                status: status,
                index: index
            )
        }

        // ── 2. Consent grants. Only now, once the jars are gone.
        let stale = staleGrantIds(
            grantIds: Array(grants.keys),
            liveAppIds: live,
            mode: status.mode,
            initialImportComplete: status.initialImportComplete
        )
        for appId in stale {
            revoke(appId)
        }
        if !stale.isEmpty {
            DiagnosticsRecorder.shared.record(
                "miniapp",
                "consent sweep: revoked \(stale.count) grant(s) with no live record"
            )
        }
        return Outcome(stores: stores, revokedGrants: stale)
    }

    /// The jar half of one pass, including everything earlier passes could not
    /// finish. Split out only for length; it is not a second owner and has no
    /// caller but `run`.
    ///
    /// Order inside it matters as much as the order between the halves:
    ///
    ///  1. **Reconcile the queue against reality first.** An owed identifier the
    ///     enumeration no longer lists is done — forget it, or the app would
    ///     keep bringing WebKit up at launch for a jar that is not there. An
    ///     owed identifier that now has a LIVE owner is forgotten too, and
    ///     emphatically not deleted: a record can come back (iCloud restore, a
    ///     resurrected CloudKit record), and the queue must never outrank the
    ///     ownership check and take a live user's logins with it.
    ///  2. **Note before attempting.** The note is durable and the attempt is
    ///     not; a kill between them must leave the app knowing it still owes the
    ///     deletion, never the other way round.
    ///  3. **Count what WebKit accepted, not what was attempted.**
    private static func sweepStores(
        owed: [MiniAppSessionStorePurgeQueue.Record],
        live: [UUID],
        consentedIds: [String],
        status: SyncStatus,
        index: StoreIndex
    ) async -> StoreOutcome {
        let found = await index.identifiers()
        let onDisk = Set(found)
        let owned = ownedIdentifiers(liveAppIds: live, consentedIds: consentedIds)

        var state: [UUID: MiniAppSessionStorePurgeQueue.State] = [:]
        for record in owed {
            if !onDisk.contains(record.identifier) || owned.contains(record.identifier) {
                MiniAppSessionStorePurgeQueue.forget(record.identifier)
            } else {
                state[record.identifier] = record.state
            }
        }

        let doomed = plan(
            found: found,
            liveAppIds: live,
            consentedIds: consentedIds,
            mode: status.mode,
            initialImportComplete: status.initialImportComplete
        )

        var reaped = 0
        var deferred = 0
        var residual = 0
        for identifier in doomed {
            // A tombstoned identifier is leftovers from a removal that already
            // succeeded — it is swept again so the directory finally goes, but
            // it is never counted as a jar that was there to lose.
            let isResidual = state[identifier] == .residual
            MiniAppSessionStorePurgeQueue.note(identifier)
            let accepted = await index.remove(identifier)
            MiniAppSessionStorePurgeQueue.recordAttempt(identifier, succeeded: accepted)
            if isResidual {
                residual += 1
            } else if accepted {
                reaped += 1
            } else {
                deferred += 1
            }
        }

        if !doomed.isEmpty {
            DiagnosticsRecorder.shared.record(
                "miniapp",
                "session store sweep: \(reaped) reaped, \(deferred) deferred, "
                + "\(residual) residual, \(found.count - doomed.count) kept"
            )
        }
        let stillOwed = MiniAppSessionStorePurgeQueue.records()
            .filter { $0.state == .pending }
        if !stillOwed.isEmpty {
            DiagnosticsRecorder.shared.record(
                "miniapp",
                "session store purge queue: \(stillOwed.count) jar(s) still owed — "
                + stillOwed.map { "\($0.identifier.uuidString.prefix(8))×\($0.attempts)" }
                    .joined(separator: " ")
            )
        }
        return .swept(
            reaped: reaped,
            kept: found.count - doomed.count,
            deferred: deferred,
            residual: residual
        )
    }
}
