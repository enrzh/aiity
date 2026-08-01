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
        // Agents were missing entirely — a backup that omits them means the
        // app's only "survives deletion" path silently loses the user's roster.
        if let agents = jsonValue(atFile: "agents.json") { payload["agents"] = agents }
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
        if let agents = jsonValue(atFile: "agents.json") as? [[String: Any]], !agents.isEmpty {
            parts.append("\(agents.count) Agenten")
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

    // MARK: - Import

    struct RestoreResult {
        var addedApps = 0
        var skippedApps = 0
        var restoredSkills = false
        var restoredChats = false
        var restoredAgents = false

        var summary: String {
            var parts: [String] = []
            parts.append("\(addedApps) Mini-Apps ergänzt")
            if skippedApps > 0 { parts.append("\(skippedApps) schon vorhanden") }
            if restoredSkills { parts.append(String(localized: "Skills übernommen")) }
            if restoredChats { parts.append(String(localized: "Chats übernommen")) }
            if restoredAgents { parts.append(String(localized: "Agenten übernommen")) }
            return parts.joined(separator: " · ")
        }
    }

    enum RestoreError: LocalizedError, Equatable {
        case unreadable
        case wrongFormat

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Die Datei konnte nicht gelesen werden."
            case .wrongFormat: return "Das ist kein aiity-Backup."
            }
        }
    }

    /// Merge a backup into the current state. Deliberately **additive**: apps
    /// already present (matched on id) are left untouched rather than
    /// overwritten, so importing an old file can never silently roll back newer
    /// work. Nothing is ever deleted by an import.
    ///
    /// Returns the decoded mini-apps for the caller to insert — this type has no
    /// access to the SwiftData context, and inserting is the caller's job.
    static func restore(from data: Data, existingIds: Set<UUID>) throws -> (result: RestoreResult, apps: [MiniApp]) {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RestoreError.unreadable
        }
        guard payload["format"] as? String == "aiity-backup" else {
            throw RestoreError.wrongFormat
        }

        var result = RestoreResult()
        var apps: [MiniApp] = []

        for entry in payload["miniApps"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String,
                  let html = entry["html"] as? String else { continue }
            if let idString = entry["id"] as? String,
               let id = UUID(uuidString: idString),
               existingIds.contains(id) {
                result.skippedApps += 1
                continue
            }
            let symbol = entry["iconSymbol"] as? String
            let app = MiniApp(
                name: name,
                emoji: entry["emoji"] as? String ?? "✨",
                html: html,
                filesJSON: entry["filesJSON"] as? String ?? "{}",
                iconSymbol: (symbol?.isEmpty ?? true) ? nil : symbol
            )
            if let idString = entry["id"] as? String, let id = UUID(uuidString: idString) {
                app.id = id
            }
            app.version = entry["version"] as? Int ?? 1
            apps.append(app)
            result.addedApps += 1
        }

        // Skills and chats are whole-file JSON; only write them when the device
        // has none, so an import never clobbers a live conversation history.
        if let skills = payload["skills"], writeIfAbsent(skills, toFile: "skills.json") {
            result.restoredSkills = true
        }
        if let chats = payload["chats"], writeIfAbsent(chats, toFile: "chat-threads.json") {
            result.restoredChats = true
        }
        if let agents = payload["agents"], writeIfAbsent(agents, toFile: "agents.json") {
            result.restoredAgents = true
        }

        return (result, apps)
    }

    /// True when the file was written (it did not exist or held nothing).
    private static func writeIfAbsent(_ value: Any, toFile name: String) -> Bool {
        let url = applicationSupport.appendingPathComponent(name)
        if let existing = try? Data(contentsOf: url), existing.count > 2 { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
