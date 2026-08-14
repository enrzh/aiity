import Foundation

/// File-based version history for a saved mini-app's HTML. A revision is
/// written right before an AI edit result or a history restore overwrites the
/// current document, so no state is ever the only copy of itself.
///
/// Deliberately LOCAL-ONLY, outside the CloudKit-synced `MiniApp` model: up to
/// 20 full HTML documents per app would multiply every record's payload
/// through sync for a feature that is about undoing what happened on THIS
/// device — and any new `MiniApp` attribute has to survive records from builds
/// that predate it (see the model's header). So: no schema change, no sync
/// bloat, and a device only ever sees the revisions it made itself.
///
/// Layout: `Application Support/MiniAppRevisions/<appId>/<ISO-timestamp>.html`
/// plus one tiny `index.json` per app (the metadata the history list shows).
/// Deletion is owned by the two existing delete paths: the library's delete
/// confirmation (local deletes, immediate) and `MiniAppSessionStoreSweep`
/// (mirrored deletes, where revisions are one more reconciled resource).
enum MiniAppRevisionStore {
    struct Revision: Codable, Equatable, Identifiable {
        var fileName: String
        var savedAt: Date
        var bytes: Int
        var id: String { fileName }
    }

    /// Cap per app; the oldest revision is pruned first.
    static let maxRevisionsPerApp = 20

    /// Test seam only. Production always uses Application Support.
    static var baseDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MiniAppRevisions", isDirectory: true)

    static func directory(for appId: UUID) -> URL {
        baseDirectory.appendingPathComponent(appId.uuidString, isDirectory: true)
    }

    /// Newest first — the index is maintained in that order by `record`, so
    /// this is a read, not a sort (two saves inside one second stay in
    /// insertion order, which a re-sort on equal dates could not guarantee).
    static func revisions(appId: UUID) -> [Revision] {
        loadIndex(appId: appId)
    }

    static func html(appId: UUID, revision: Revision) -> String? {
        // The name comes from our own index, but a stored path gets the same
        // no-traversal treatment as any other stored path.
        guard !revision.fileName.contains("/"), !revision.fileName.contains("..") else { return nil }
        let url = directory(for: appId).appendingPathComponent(revision.fileName)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Record `html` as the newest revision and prune beyond the cap. Callers
    /// pass the RUNNABLE html (companions inlined) so a restored revision is
    /// self-contained without the `filesJSON` of a later version on top.
    static func record(appId: UUID, html: String, at date: Date = .now) {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let data = Data(html.utf8)
        let dir = directory(for: appId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let name = availableFileName(in: dir, at: date)
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        } catch {
            return
        }
        var index = loadIndex(appId: appId)
        index.insert(Revision(fileName: name, savedAt: date, bytes: data.count), at: 0)
        while index.count > maxRevisionsPerApp {
            let oldest = index.removeLast()
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(oldest.fileName))
        }
        saveIndex(index, appId: appId)
    }

    /// The whole history of one app — the delete paths' single call.
    static func removeAll(appId: UUID) {
        try? FileManager.default.removeItem(at: directory(for: appId))
    }

    /// Every app id that still owns revisions on disk — what the launch sweep
    /// compares against the live records. Non-UUID names are ignored, never
    /// deleted: whatever they are, this store did not create them.
    static func revisionAppIds() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: baseDirectory.path)) ?? []
        return names.compactMap(UUID.init(uuidString:))
    }

    // MARK: - Index

    private static func indexURL(appId: UUID) -> URL {
        directory(for: appId).appendingPathComponent("index.json")
    }

    private static func loadIndex(appId: UUID) -> [Revision] {
        guard let data = try? Data(contentsOf: indexURL(appId: appId)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Revision].self, from: data)) ?? []
    }

    private static func saveIndex(_ index: [Revision], appId: UUID) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: indexURL(appId: appId), options: .atomic)
    }

    /// `2026-08-14T10-00-00Z.html`, uniquified: colons are replaced (illegal
    /// on file systems an iTunes/Finder copy can land on), and two saves
    /// inside one second must not overwrite each other.
    private static func availableFileName(in dir: URL, at date: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        var name = "\(stamp).html"
        var counter = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(stamp)-\(counter).html"
            counter += 1
        }
        return name
    }
}
