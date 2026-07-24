import Foundation

/// Exports the user's own content — mini-apps, skills and chat threads — into a
/// single JSON file so it survives app deletion, a device change, or a corrupt
/// store. Deliberately excludes secrets: API keys and OAuth tokens live in the
/// Keychain and are never written into a shareable file.
enum BackupService {
    static let fileName = "aiity-backup.json"

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Build the backup payload. `apps` comes from the SwiftData store; skills and
    /// chats are read from their on-disk JSON so this stays free of store plumbing.
    static func makeBackup(apps: [MiniApp], createdAt: Date) -> Data {
        let appPayload: [[String: Any]] = apps.map { app in
            [
                "id": app.id.uuidString,
                "name": app.name,
                "emoji": app.emoji,
                "html": app.html,
                "filesJSON": app.filesJSON ?? "{}",
                "iconSymbol": app.iconSymbol ?? "",
                "version": app.version,
                "updatedAt": ISO8601DateFormatter().string(from: app.updatedAt),
            ]
        }

        var payload: [String: Any] = [
            "format": "aiity-backup",
            "version": 1,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "miniApps": appPayload,
            "note": "Enthält keine API-Keys oder Logins — die bleiben im Schlüsselbund des Geräts.",
        ]
        if let skills = jsonValue(atFile: "skills.json") { payload["skills"] = skills }
        if let chats = jsonValue(atFile: "chat-threads.json") { payload["chats"] = chats }

        return (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
    }

    /// Write the backup to a temporary file and return its URL (for ShareLink).
    static func writeBackup(apps: [MiniApp], createdAt: Date) -> URL? {
        let data = makeBackup(apps: apps, createdAt: createdAt)
        guard !data.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Summary for the UI so the user knows what a backup will contain.
    static func summary(apps: [MiniApp]) -> String {
        var parts = ["\(apps.count) Mini-Apps"]
        if let skills = jsonValue(atFile: "skills.json") as? [[String: Any]] {
            parts.append("\(skills.filter { ($0["builtin"] as? Bool) != true }.count) eigene Skills")
        }
        if let chats = jsonValue(atFile: "chat-threads.json") as? [String: Any],
           let threads = chats["threads"] as? [[String: Any]] {
            parts.append("\(threads.count) Chats")
        }
        return parts.joined(separator: " · ")
    }

    private static func jsonValue(atFile name: String) -> Any? {
        let url = applicationSupport.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
