import Foundation

/// The durable list of persistent `WKWebsiteDataStore` identifiers this app has
/// decided to delete but has not yet watched disappear.
///
/// **Why a note on disk is needed at all.** Two measured WebKit facts, both
/// reproduced on device:
///
///  1. A data store **this process has opened** cannot be deleted for the rest
///     of the process's life. `WKWebsiteDataStore.remove(forIdentifier:)`
///     answers `WKWebSiteDataStore Code=1 "Failed to delete files on disk"`,
///     every time. That is exactly the common delete: the user opens a browser
///     mini-app, closes the sheet, deletes the app — one launch, one process.
///     The jar, with the site's real logins in it, stays on disk.
///  2. A **fresh process can** delete it, because it never opened it.
///
/// So the reliable deleter is the *next launch*, and the only way the next
/// launch can know what to delete is a note that outlives the process: the
/// record is gone by then, and the consent grant — the signal
/// `MiniAppSessionStoreSweep` uses to decide it must enumerate at all — was
/// revoked in the same breath. Without this list that jar is unreachable
/// forever. With it, `MiniAppSessionStoreSweep` retries on every launch until
/// WebKit stops listing the identifier.
///
/// **The one-way walk.** An identifier enters as `.pending` (we mean to delete
/// it, WebKit has not accepted yet), becomes `.residual` the moment a removal
/// IS accepted, and is forgotten only when an enumeration no longer lists it —
/// or when a live owner turns up for it again (a record restored from iCloud),
/// in which case it must never be deleted at all. `.residual` exists because a
/// *successful* removal still leaves a stub directory behind
/// (`…/WebsiteDataStore/<uuid>/ResourceLoadStatistics`) that the next process
/// enumerates as a data store: without the tombstone that stub reads as a live
/// orphaned cookie jar on every launch, forever.
///
/// Written through `UserDefaults` for the same reason `MiniAppConsent` is: it
/// has to survive a kill immediately after the tap, and it is a handful of
/// UUIDs, not user data.
enum MiniAppSessionStorePurgeQueue {

    private static let key = "miniapp-store-purge-v1"

    /// A ceiling so a pathological loop cannot grow `UserDefaults` without
    /// bound. Dropping an entry costs little: while any `.browser` grant still
    /// exists the sweep re-discovers every unowned jar by enumeration anyway —
    /// this list only *adds* the case where no grant is left to trigger that.
    /// The OLDEST entries are the ones kept, because they are the ones that
    /// have already refused to go.
    static let maximumEntries = 200

    /// Where an identifier stands in the walk described above.
    enum State: String, Codable {
        /// No removal has been accepted for it yet. What is on disk under this
        /// identifier is a real cookie jar — keep trying.
        case pending
        /// WebKit accepted a removal. Anything a later enumeration still lists
        /// for it is WebKit's own leftover metadata directory, not a jar.
        case residual
    }

    struct Record: Codable, Equatable {
        var identifier: UUID
        var state: State
        /// When the app first decided this jar had to go — the age of a stuck
        /// purge is the whole story in a diagnostics report.
        var firstNotedAt: Date
        /// How many removals have been attempted for it.
        var attempts: Int
    }

    // MARK: - Reading

    /// Everything still owed, oldest note first (stable, so logs and reports
    /// do not reshuffle between launches).
    static func records() -> [Record] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Record].self, from: data)
        else { return [] }
        return decoded.sorted {
            $0.firstNotedAt == $1.firstNotedAt
                ? $0.identifier.uuidString < $1.identifier.uuidString
                : $0.firstNotedAt < $1.firstNotedAt
        }
    }

    static func record(for identifier: UUID) -> Record? {
        records().first { $0.identifier == identifier }
    }

    static var isEmpty: Bool { records().isEmpty }

    // MARK: - Writing

    /// Note the intent to delete, BEFORE attempting it.
    ///
    /// Deliberately create-only: an identifier already known as `.residual` must
    /// not be walked back to `.pending`, or WebKit's leftover directory would
    /// read as a live jar again on the next launch.
    static func note(_ identifier: UUID, now: Date = Date()) {
        var all = records()
        guard !all.contains(where: { $0.identifier == identifier }) else { return }
        all.append(Record(identifier: identifier, state: .pending, firstNotedAt: now, attempts: 0))
        save(all)
    }

    /// Record what WebKit answered for one removal attempt.
    ///
    /// Success moves the entry to `.residual` — believed gone, still awaiting
    /// the confirmation only a later enumeration can give. Failure leaves the
    /// state alone: `.pending` keeps retrying, and a `.residual` that refuses to
    /// go is still only leftovers.
    static func recordAttempt(_ identifier: UUID, succeeded: Bool, now: Date = Date()) {
        var all = records()
        if let index = all.firstIndex(where: { $0.identifier == identifier }) {
            all[index].attempts += 1
            if succeeded { all[index].state = .residual }
        } else {
            all.append(Record(
                identifier: identifier,
                state: succeeded ? .residual : .pending,
                firstNotedAt: now,
                attempts: 1
            ))
        }
        save(all)
    }

    /// Stop owing this identifier anything. The two callers that may do this are
    /// in `MiniAppSessionStoreSweep`: the enumeration no longer lists it (done),
    /// or a live record owns it again (never delete it).
    static func forget(_ identifier: UUID) {
        let all = records()
        let kept = all.filter { $0.identifier != identifier }
        guard kept.count != all.count else { return }
        save(kept)
    }

    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Overwrite the whole list. Exists for the tests' snapshot/restore — the
    /// list is device-global state, like the consent map, and a test that left
    /// its own entries behind would make the next one enumerate WebKit.
    static func replaceAll(_ all: [Record]) {
        save(all)
    }

    private static func save(_ all: [Record]) {
        let trimmed = all.count <= maximumEntries
            ? all
            : Array(all.sorted { $0.firstNotedAt < $1.firstNotedAt }.prefix(maximumEntries))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
