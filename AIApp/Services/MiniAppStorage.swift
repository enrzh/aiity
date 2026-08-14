import Foundation

/// Durable per-mini-app key-value storage behind `window.aiity.storage`.
///
/// One JSON file per app id under Application Support/MiniAppStorage/, so a
/// mini-app's data survives app restarts and mini-app reloads. String keys and
/// values only, 1 MB per app measured on the encoded file. Needs no consent:
/// the app reads and writes only its own data and nothing here can leave the
/// device — but it MUST die with the app, which is why
/// `MiniAppSessionStoreSweep` reconciles `storedAppIds()` against the live
/// records on every pass.
enum MiniAppStorage {
    static let maxBytesPerApp = 1_048_576

    /// Test seam: redirect the on-disk root so tests never touch (or depend
    /// on) the real container. Same pattern as
    /// `MiniAppNotificationService.gateOverride`.
    static var rootOverride: URL?

    static func item(appId: String, key: String) -> String? {
        load(appId: appId)[key]
    }

    /// `false` means the write was refused because it would push the app's
    /// file over `maxBytesPerApp`; the previous contents stay untouched.
    @discardableResult
    static func setItem(appId: String, key: String, value: String) -> Bool {
        var items = load(appId: appId)
        items[key] = value
        guard let data = try? JSONEncoder().encode(items), data.count <= maxBytesPerApp else {
            return false
        }
        let file = fileURL(appId: appId)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    static func removeItem(appId: String, key: String) {
        var items = load(appId: appId)
        guard items.removeValue(forKey: key) != nil else { return }
        guard !items.isEmpty else {
            wipe(appId: appId)
            return
        }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL(appId: appId), options: .atomic)
        }
    }

    static func wipe(appId: String) {
        try? FileManager.default.removeItem(at: fileURL(appId: appId))
    }

    /// Every app id that still has a file on disk — the sweep's work list.
    static func storedAppIds() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root().path) else {
            return []
        }
        return names.compactMap(appId(fromFileName:)).sorted()
    }

    // MARK: - Files

    private static func root() -> URL {
        rootOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MiniAppStorage", isDirectory: true)
    }

    private static func fileURL(appId: String) -> URL {
        root().appendingPathComponent(fileName(for: appId))
    }

    // App ids are UUID strings or `preview-<hash>` today, but the id reaches
    // this API from the runner verbatim — encode anything else so it can never
    // traverse out of the storage directory.
    private static let safeCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-"))

    private static func fileName(for appId: String) -> String {
        (appId.addingPercentEncoding(withAllowedCharacters: safeCharacters) ?? appId) + ".json"
    }

    static func appId(fromFileName name: String) -> String? {
        guard name.hasSuffix(".json") else { return nil }
        return String(name.dropLast(".json".count)).removingPercentEncoding
    }

    private static func load(appId: String) -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL(appId: appId)),
              let items = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return items
    }
}
