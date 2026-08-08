import Foundation
import SwiftData

/// Remembers which storage mode each launch actually used, so the next launch
/// can tell when iCloud sync was just re-enabled after running local-only.
///
/// Why that matters: records created while the store was opened with
/// `cloudKitDatabase: .none` may never be exported retroactively once sync is
/// re-enabled — Core Data's mirroring catch-up depends on persistent-history
/// state SwiftData does not expose, and whether it happens is not provable
/// from code (device-only behavior). Defensive answer: on the first synced
/// launch after a local-only one, touch every record with an invisible +1 ms
/// `updatedAt` bump. That marks each record dirty in persistent history, so
/// the mirroring delegate exports it regardless — and if CloudKit would have
/// caught up anyway, re-exporting identical content is harmless.
enum SyncModeTransition {
    static let lastModeKey = "store.lastLaunchMode"
    static let catchUpKey = "store.pendingSyncCatchUp"

    /// Called once per launch by `SyncStatus.report` with the mode the
    /// container ladder actually landed on. Arms the catch-up flag on the
    /// local→synced transition. In-memory launches record nothing — no data
    /// was persisted, so the last REAL mode stays authoritative.
    nonisolated static func noteLaunch(mode: SyncStatus.Mode, defaults: UserDefaults = .standard) {
        let current: String
        switch mode {
        case .synced: current = "synced"
        case .localOnly, .recovered: current = "local"
        case .inMemory: return
        }
        if current == "synced", defaults.string(forKey: lastModeKey) == "local" {
            defaults.set(true, forKey: catchUpKey)
        }
        defaults.set(current, forKey: lastModeKey)
    }

    /// True exactly once after the local→synced transition; the caller then
    /// runs `touchAllRecords`. Consuming clears the flag so the touch never
    /// repeats.
    nonisolated static func consumePendingCatchUp(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: catchUpKey) else { return false }
        defaults.set(false, forKey: catchUpKey)
        return true
    }

    /// +1 ms on every record: enough to dirty it for export, small enough to
    /// preserve the user's recency ordering exactly (bumping to `.now` would
    /// scramble the library sort).
    @MainActor
    static func touchAllRecords(in context: ModelContext) {
        guard let all = try? context.fetch(FetchDescriptor<MiniApp>()), !all.isEmpty else { return }
        for app in all {
            app.updatedAt = app.updatedAt.addingTimeInterval(0.001)
        }
        try? context.save()
    }
}

/// CloudKit cannot enforce uniqueness across devices (which is why `MiniApp`
/// has no unique constraint), so two records CAN share a UUID — classically a
/// backup restored while the initial CloudKit import was still in flight, so
/// the restored copy and the cloud copy both land. `LibraryView`'s `ForEach`
/// identifies by that UUID, so duplicates corrupt the grid.
@MainActor
enum MiniAppDedup {
    /// Delete strictly-older records that share an id with a newer one.
    ///
    /// Deliberately conservative on ties: with CloudKit active a local delete
    /// is MIRRORED TO EVERY DEVICE, and two devices resolving an exact
    /// timestamp tie differently would each delete the other's survivor —
    /// destroying BOTH copies everywhere. Identical-timestamp duplicates are
    /// therefore left alone (annoying, never destructive); only a strict
    /// `updatedAt` ordering, which every device resolves identically, allows
    /// a delete.
    @discardableResult
    static func removeDuplicates(in context: ModelContext) -> Int {
        guard let all = try? context.fetch(FetchDescriptor<MiniApp>()) else { return 0 }
        var removed = 0
        for (_, group) in Dictionary(grouping: all, by: \.id) where group.count > 1 {
            guard let newest = group.max(by: { $0.updatedAt < $1.updatedAt }) else { continue }
            for candidate in group where candidate !== newest && candidate.updatedAt < newest.updatedAt {
                context.delete(candidate)
                removed += 1
            }
        }
        if removed > 0 {
            try? context.save()
        }
        return removed
    }
}
