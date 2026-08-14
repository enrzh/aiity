import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Mirrors the user's saved mini-apps into the system Spotlight index, and
/// keeps the Home-Screen widget's pin honest while it is at it.
///
/// **Why a full reconcile instead of incremental updates.** The library is
/// CloudKit-mirrored: records appear and disappear without any local
/// create/delete path running (the same fact that motivates
/// `MiniAppSessionStoreSweep`). An incremental "index on create, deindex on
/// delete" therefore misses exactly the interesting cases. Every pass here is
/// `deleteAll(domain)` + reindex of the live records — a couple hundred tiny
/// items at most (the library the picker caps at `MiniAppIndex.limit` is the
/// same order of magnitude), so the reset costs nothing and can never drift.
///
/// **Where it runs.** Two callers, deliberately the same choke points that
/// already own "the library may have changed":
///  * `RootView.refreshMiniAppIndex()` — launch, foreground, background — only
///    when the name snapshot actually changed, so Spotlight is not churned on
///    every foreground.
///  * `MiniAppSessionStoreSweep.run` — the once-per-launch pass that already
///    reconciles everything else a mini-app leaves behind outside its record.
///
/// **Bias: keep.** An unreadable library is never read as "no apps exist" —
/// wiping the whole domain (and the pin) over a transient fetch error would be
/// the same mistake the session-store sweep refuses to make. The pass skips
/// instead; a stale Spotlight result for one more cycle opens nothing wrong,
/// because activation resolves the UUID against the real store.
///
/// Tapping a result arrives as an `NSUserActivity` of type
/// `CSSearchableItemActionType` at the app root, with the item's
/// `uniqueIdentifier` — this app's `MiniApp.id` — in the userInfo; the root
/// feeds it into the existing `IntentRouter` mini-app route.
@MainActor
enum MiniAppSpotlightIndex {
    /// Fixed domain for everything this app ever indexes, so one
    /// `deleteSearchableItems(withDomainIdentifiers:)` is a complete reset.
    static let domainIdentifier = "miniapps"

    /// Name-and-icon projection of a record — all Spotlight (and the pin)
    /// needs. Same idea as `MiniAppIndex.Entry`, plus the emoji, which becomes
    /// a search keyword and the widget's tile glyph.
    struct App: Equatable {
        var id: UUID
        var name: String
        var emoji: String
        var symbol: String?
    }

    /// What one pass did — returned, not only logged, so every branch is
    /// assertable in a test.
    struct Outcome: Equatable {
        /// Items handed to the system index this pass.
        var indexed: Int = 0
        /// The pinned app no longer exists; the pin was cleared and the widget
        /// told to redraw its empty state.
        var clearedStalePin = false
        /// The pinned app still exists but was renamed or re-iconed since it
        /// was pinned; the snapshot was rewritten so the widget catches up.
        var refreshedPin = false
        /// The record fetch failed. Nothing was touched — see *Bias: keep*.
        var skippedUnreadableLibrary = false
    }

    // MARK: - Item construction (pure)

    /// One mini-app as a `CSSearchableItem`: unique id = the record's UUID
    /// (what activation hands back), fixed domain, title = the app's name,
    /// keywords = the name's words plus the emoji. No thumbnail in v1 —
    /// Spotlight falls back to the app icon, which is honest enough.
    static func item(for app: App) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = app.name.isEmpty ? String(localized: "Mini-App") : app.name
        attributes.contentDescription = String(localized: "Mini-App in aiity öffnen")
        attributes.keywords = keywords(name: app.name, emoji: app.emoji)
        return CSSearchableItem(
            uniqueIdentifier: app.id.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }

    /// The name split on whitespace, plus the emoji — so "Einkaufs Liste" is
    /// findable by either word and "🛒" by the glyph the keyboard offers.
    static func keywords(name: String, emoji: String) -> [String] {
        var words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        if !emoji.isEmpty { words.append(emoji) }
        return words
    }

    // MARK: - Spotlight seam

    /// The two `CSSearchableIndex` calls this needs, behind a seam for the
    /// same reason `MiniAppSessionStoreSweep.StoreIndex` exists: both touch
    /// the REAL system index of whatever process runs them, and the reconcile
    /// logic must be testable without that. Both are best-effort — a failed
    /// index write self-heals on the next pass, because every pass is a full
    /// reset.
    struct Index {
        var deleteDomain: @MainActor (String) async -> Void
        var indexItems: @MainActor ([CSSearchableItem]) async -> Void

        static let spotlight = Index(
            deleteDomain: { domain in
                guard CSSearchableIndex.isIndexingAvailable() else { return }
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    CSSearchableIndex.default().deleteSearchableItems(
                        withDomainIdentifiers: [domain]
                    ) { error in
                        if let error {
                            // Completion handlers arrive on a background
                            // queue; DiagnosticsRecorder serializes internally.
                            DiagnosticsRecorder.shared.record(
                                "miniapp",
                                "spotlight domain delete failed: \(error.localizedDescription)"
                            )
                        }
                        done.resume()
                    }
                }
            },
            indexItems: { items in
                guard CSSearchableIndex.isIndexingAvailable(), !items.isEmpty else { return }
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    CSSearchableIndex.default().indexSearchableItems(items) { error in
                        if let error {
                            DiagnosticsRecorder.shared.record(
                                "miniapp",
                                "spotlight index failed: \(error.localizedDescription)"
                            )
                        }
                        done.resume()
                    }
                }
            }
        )
    }

    // MARK: - Test seams
    //
    // Static vars rather than parameters (the `MiniAppIndex.storageURL`
    // pattern, not the sweep's defaulted-parameter one) so the sweep's call
    // stays a bare `reconcile(context:)` — its signature is not this feature's
    // to grow. Production never reassigns any of them.

    /// The system index. Tests swap in a recorder.
    static var systemIndex: Index = .spotlight
    /// The live records, or `nil` when the library cannot be read — `nil` is
    /// emphatically NOT the empty list, same contract as
    /// `MiniAppSessionStoreSweep.liveAppIds(in:)`.
    static var records: @MainActor (ModelContext) -> [App]? = MiniAppSpotlightIndex.liveApps(in:)
    /// The current pin, if any.
    static var pinned: @MainActor () -> PinnedMiniApp? = { PinnedMiniAppStore.load() }
    /// Rewrite the pin snapshot (also pokes WidgetKit).
    static var storePin: @MainActor (PinnedMiniApp) -> Void = { PinnedMiniAppStore.pin($0) }
    /// Drop the pin (also pokes WidgetKit).
    static var clearPin: @MainActor () -> Void = { PinnedMiniAppStore.clear() }

    // MARK: - Record fetch

    /// `propertiesToFetch` keeps the bundled HTML out of it, exactly like
    /// `RootView.refreshMiniAppIndex` — Spotlight needs a name and an icon,
    /// not hundreds of KB per app.
    static func liveApps(in context: ModelContext) -> [App]? {
        var descriptor = FetchDescriptor<MiniApp>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.propertiesToFetch = [\.id, \.name, \.emoji, \.iconSymbol]
        guard let apps = try? context.fetch(descriptor) else { return nil }
        return apps.map { App(id: $0.id, name: $0.name, emoji: $0.emoji, symbol: $0.iconSymbol) }
    }

    // MARK: - Reconcile

    /// One full pass: reset the Spotlight domain, reindex every live record,
    /// then square the widget pin against the same list — refresh its snapshot
    /// if the record changed, clear it if the record is gone (the mirrored
    /// delete no local code path ever sees).
    @discardableResult
    static func reconcile(context: ModelContext) async -> Outcome {
        guard let live = records(context) else {
            return Outcome(skippedUnreadableLibrary: true)
        }

        await systemIndex.deleteDomain(domainIdentifier)
        await systemIndex.indexItems(live.map(item(for:)))

        var outcome = Outcome(indexed: live.count)
        if let pin = pinned() {
            if let app = live.first(where: { $0.id == pin.id }) {
                let fresh = PinnedMiniApp(
                    id: app.id, name: app.name, emoji: app.emoji, iconSymbol: app.symbol
                )
                if fresh != pin {
                    storePin(fresh)
                    outcome.refreshedPin = true
                }
            } else {
                clearPin()
                outcome.clearedStalePin = true
            }
        }

        DiagnosticsRecorder.shared.record(
            "miniapp",
            "spotlight reconcile: \(outcome.indexed) indexed"
            + (outcome.clearedStalePin ? ", stale pin cleared" : "")
            + (outcome.refreshedPin ? ", pin refreshed" : "")
        )
        return outcome
    }
}
