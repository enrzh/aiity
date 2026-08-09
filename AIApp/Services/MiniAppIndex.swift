import Foundation

/// A name-only snapshot of the user's saved mini-apps, for the Shortcuts /
/// Siri entity picker.
///
/// **Why a snapshot instead of reading SwiftData from the entity query.**
/// `EntityQuery` runs wherever the system wants it — including a background
/// launch of the app purely to fill in a Shortcuts parameter list. Opening the
/// real store there is the wrong shape twice over:
///  * the container is CloudKit-backed (`.automatic`), so opening it spins up
///    sync machinery for what is meant to be a picker refresh, and
///  * a `MiniApp` row carries the whole bundled HTML — hundreds of KB each —
///    while the picker needs a name and an icon.
///
/// So the app writes this tiny JSON list whenever the library can have changed
/// (launch, and again when the scene goes to background, which is the last
/// moment anything created during the session is still guaranteed reachable),
/// and the query only ever reads a few hundred bytes off the main actor.
///
/// Known and accepted staleness: mini-apps that arrive from another device via
/// CloudKit while aiity is not running are absent from the picker until the
/// next launch. Opening one from Shortcuts still resolves by id, so a stale
/// entry never opens the wrong app — the id is looked up in the real store.
enum MiniAppIndex {
    struct Entry: Codable, Equatable, Sendable, Identifiable {
        var id: UUID
        var name: String
        /// SF Symbol when the app has one; the picker falls back to a generic
        /// glyph rather than trying to render an emoji as an image.
        var symbol: String?
    }

    /// Hard ceiling on the picker. A user with thousands of apps does not want
    /// to scroll them in Siri, and this keeps the file trivially small.
    static let limit = 200

    /// Test seam only. Production always uses Application Support.
    static var storageURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("miniapp-index.json")
    }()

    /// Read the snapshot. Safe to call off the main actor; returns `[]` for a
    /// missing or unreadable file, which is the correct answer for "no apps
    /// yet" and also the only sane answer for a corrupt one.
    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Persist the snapshot. Returns `true` when the content actually changed,
    /// so the caller can skip `updateAppShortcutParameters()` — telling the
    /// system to re-index on every foreground would be pure churn.
    @discardableResult
    static func save(_ entries: [Entry]) -> Bool {
        let capped = Array(entries.prefix(limit))
        guard capped != load() else { return false }
        guard let data = try? JSONEncoder().encode(capped) else { return false }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL, options: .atomic)
        return true
    }
}
