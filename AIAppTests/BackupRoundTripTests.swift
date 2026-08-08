import XCTest
import SwiftData
@testable import AIApp

/// Proves the export → import path actually carries data across, and that
/// import is additive. Written because the import shipped without a single
/// round-trip ever having been run: it compiled, the suite was green, and
/// neither fact says a backup can be restored.
@MainActor
final class BackupRoundTripTests: XCTestCase {

    /// In-memory store so a test never touches the real one.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MiniApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func sampleApps() -> [MiniApp] {
        [
            MiniApp(name: "Trinkgeld", emoji: "💰", html: "<html>tip</html>", iconSymbol: "dollarsign.circle"),
            MiniApp(name: "Notizen", emoji: "📝", html: "<html>notes</html>"),
        ]
    }

    func testExportedBackupRestoresEveryApp() throws {
        let apps = sampleApps()
        let data = BackupService.makeBackup(apps: apps, createdAt: .now)
        XCTAssertFalse(data.isEmpty)

        let (result, restored) = try BackupService.restore(from: data, existingIds: [])
        XCTAssertEqual(result.addedApps, 2)
        XCTAssertEqual(result.skippedApps, 0)
        XCTAssertEqual(Set(restored.map(\.name)), ["Trinkgeld", "Notizen"])

        // The payload must survive intact, not just the names.
        let tip = restored.first { $0.name == "Trinkgeld" }
        XCTAssertEqual(tip?.html, "<html>tip</html>")
        XCTAssertEqual(tip?.emoji, "💰")
        XCTAssertEqual(tip?.iconSymbol, "dollarsign.circle")
        // Identity is preserved, which is what makes re-import idempotent.
        XCTAssertEqual(Set(restored.map(\.id)), Set(apps.map(\.id)))
    }

    func testReimportingTheSameBackupAddsNothing() throws {
        let apps = sampleApps()
        let data = BackupService.makeBackup(apps: apps, createdAt: .now)

        let (result, restored) = try BackupService.restore(
            from: data,
            existingIds: Set(apps.map(\.id))
        )
        XCTAssertEqual(result.addedApps, 0, "already-present apps must not be duplicated")
        XCTAssertEqual(result.skippedApps, 2)
        XCTAssertTrue(restored.isEmpty)
    }

    func testImportOnlyAddsWhatIsMissing() throws {
        let apps = sampleApps()
        let data = BackupService.makeBackup(apps: apps, createdAt: .now)

        // Device already has the first app but not the second.
        let (result, restored) = try BackupService.restore(
            from: data,
            existingIds: [apps[0].id]
        )
        XCTAssertEqual(result.addedApps, 1)
        XCTAssertEqual(result.skippedApps, 1)
        XCTAssertEqual(restored.first?.name, "Notizen")
    }

    func testRestoredAppsInsertIntoAStore() throws {
        let context = try makeContext()
        let data = BackupService.makeBackup(apps: sampleApps(), createdAt: .now)
        let (_, restored) = try BackupService.restore(from: data, existingIds: [])
        for app in restored { context.insert(app) }
        try context.save()

        let stored = try context.fetch(FetchDescriptor<MiniApp>())
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.contains { $0.html == "<html>notes</html>" })
    }

    // MARK: - Timestamp fidelity

    func testTimestampsSurviveRoundTrip() throws {
        let app = MiniApp(name: "Alt", emoji: "🕰️", html: "<html>old</html>")
        app.createdAt = Date(timeIntervalSince1970: 1_600_000_000)
        app.updatedAt = Date(timeIntervalSince1970: 1_650_000_000)

        let data = BackupService.makeBackup(apps: [app], createdAt: .now, directory: try makeTempDir())
        let (_, restored) = try BackupService.restore(from: data, existingIds: [], directory: try makeTempDir())

        // ISO8601 carries second precision — that is enough for sorting.
        XCTAssertEqual(restored.first?.createdAt.timeIntervalSince1970 ?? 0, 1_600_000_000, accuracy: 1,
                       "createdAt must survive the round trip, not reset to import time")
        XCTAssertEqual(restored.first?.updatedAt.timeIntervalSince1970 ?? 0, 1_650_000_000, accuracy: 1,
                       "without updatedAt every restored app sorts as brand-new")
    }

    func testBackupWithoutTimestampsRestoresAsCurrent() throws {
        // Older backups predate the timestamp fields — they must still import.
        let payload: [String: Any] = [
            "format": "aiity-backup",
            "version": 1,
            "miniApps": [["name": "Alt", "emoji": "🕰️", "html": "<html>x</html>"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let (_, restored) = try BackupService.restore(from: data, existingIds: [], directory: try makeTempDir())
        XCTAssertEqual(restored.first?.updatedAt.timeIntervalSinceNow ?? -999, 0, accuracy: 5)
    }

    // MARK: - Whole-file restore semantics (chats / skills / agents)

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ object: Any, to file: String, in directory: URL) throws {
        try JSONSerialization.data(withJSONObject: object)
            .write(to: directory.appendingPathComponent(file))
    }

    private func chatsBlob(messageText: String?) -> [String: Any] {
        let messages: [[String: Any]] = messageText.map { [["role": "user", "content": $0]] } ?? []
        return ["threads": [["id": UUID().uuidString, "title": "T", "messages": messages]]]
    }

    private func payload(with extras: [String: Any]) throws -> Data {
        var payload: [String: Any] = ["format": "aiity-backup", "version": 1, "miniApps": []]
        for (key, value) in extras { payload[key] = value }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// The old check was literal bytes (`> 2`): a device whose chat store was
    /// an empty `{"threads":[]}` envelope — or one blank auto-created thread —
    /// could never restore chats, forever.
    func testChatsRestoreOntoSemanticallyEmptyDevice() throws {
        for emptyish in [["threads": [[String: Any]]()], chatsBlob(messageText: nil)] {
            let dir = try makeTempDir()
            try write(emptyish, to: "chat-threads.json", in: dir)

            let data = try payload(with: ["chats": chatsBlob(messageText: "hallo")])
            let (result, _) = try BackupService.restore(from: data, existingIds: [], directory: dir)

            XCTAssertTrue(result.restoredChats)
            let onDisk = try JSONSerialization.jsonObject(
                with: Data(contentsOf: dir.appendingPathComponent("chat-threads.json"))
            ) as? [String: Any]
            let threads = onDisk?["threads"] as? [[String: Any]]
            let firstMessages = threads?.first?["messages"] as? [[String: Any]]
            XCTAssertEqual(firstMessages?.first?["content"] as? String, "hallo")
        }
    }

    func testChatsNeverOverwriteRealHistory() throws {
        let dir = try makeTempDir()
        try write(chatsBlob(messageText: "echte Unterhaltung"), to: "chat-threads.json", in: dir)

        let data = try payload(with: ["chats": chatsBlob(messageText: "aus dem Backup")])
        let (result, _) = try BackupService.restore(from: data, existingIds: [], directory: dir)

        XCTAssertFalse(result.restoredChats)
        let onDisk = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("chat-threads.json"))
        ) as? [String: Any]
        let threads = onDisk?["threads"] as? [[String: Any]]
        let firstMessages = threads?.first?["messages"] as? [[String: Any]]
        XCTAssertEqual(firstMessages?.first?["content"] as? String, "echte Unterhaltung")
    }

    func testMeaninglessPayloadChatsAreNotReportedAsRestored() throws {
        let dir = try makeTempDir()
        let data = try payload(with: ["chats": ["threads": [[String: Any]]()]])
        let (result, _) = try BackupService.restore(from: data, existingIds: [], directory: dir)
        XCTAssertFalse(result.restoredChats, "an empty envelope is nothing worth calling 'übernommen'")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("chat-threads.json").path))
    }

    /// SkillStore persists the builtins on first launch, so skills.json always
    /// exists — mere existence must not block restoring the user's own skills.
    func testSkillsWithOnlyBuiltinsCountAsAbsent() throws {
        let dir = try makeTempDir()
        try write([["name": "Standard", "builtin": true]], to: "skills.json", in: dir)

        let data = try payload(with: ["skills": [
            ["name": "Standard", "builtin": true],
            ["name": "Meine Regeln", "builtin": false],
        ]])
        let (result, _) = try BackupService.restore(from: data, existingIds: [], directory: dir)
        XCTAssertTrue(result.restoredSkills)
    }

    func testUserAuthoredSkillsAreNeverOverwritten() throws {
        let dir = try makeTempDir()
        try write([["name": "Lokal geschrieben", "builtin": false]], to: "skills.json", in: dir)

        let data = try payload(with: ["skills": [["name": "Aus Backup", "builtin": false]]])
        let (result, _) = try BackupService.restore(from: data, existingIds: [], directory: dir)
        XCTAssertFalse(result.restoredSkills)
    }

    func testAgentsRestoreOnlyOntoEmptyRoster() throws {
        let emptyDir = try makeTempDir()
        try write([[String: Any]](), to: "agents.json", in: emptyDir)
        let data = try payload(with: ["agents": [["id": UUID().uuidString, "name": "Recherche"]]])
        let (restoredResult, _) = try BackupService.restore(from: data, existingIds: [], directory: emptyDir)
        XCTAssertTrue(restoredResult.restoredAgents)

        let busyDir = try makeTempDir()
        try write([["id": UUID().uuidString, "name": "Bestehend"]], to: "agents.json", in: busyDir)
        let (keptResult, _) = try BackupService.restore(from: data, existingIds: [], directory: busyDir)
        XCTAssertFalse(keptResult.restoredAgents)
    }

    // MARK: - Duplicate-UUID dedup

    func testDedupKeepsStrictlyNewestForSharedId() throws {
        let context = try makeContext()
        let id = UUID()
        let older = MiniApp(name: "Alt", emoji: "1️⃣", html: "<html>a</html>")
        older.id = id
        older.updatedAt = Date(timeIntervalSince1970: 100)
        let newer = MiniApp(name: "Neu", emoji: "2️⃣", html: "<html>b</html>")
        newer.id = id
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        context.insert(older)
        context.insert(newer)
        try context.save()

        XCTAssertEqual(MiniAppDedup.removeDuplicates(in: context), 1)
        let remaining = try context.fetch(FetchDescriptor<MiniApp>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.name, "Neu")
    }

    /// Two devices resolving an exact tie differently would each delete the
    /// other's survivor — and CloudKit mirrors deletes, so BOTH copies would
    /// vanish everywhere. Ties must never delete.
    func testDedupNeverDeletesOnExactTie() throws {
        let context = try makeContext()
        let id = UUID()
        let stamp = Date(timeIntervalSince1970: 300)
        for name in ["Kopie A", "Kopie B"] {
            let app = MiniApp(name: name, emoji: "🌀", html: "<html>x</html>")
            app.id = id
            app.updatedAt = stamp
            context.insert(app)
        }
        try context.save()

        XCTAssertEqual(MiniAppDedup.removeDuplicates(in: context), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MiniApp>()).count, 2)
    }

    func testDedupLeavesDistinctIdsAlone() throws {
        let context = try makeContext()
        for app in sampleApps() { context.insert(app) }
        try context.save()

        XCTAssertEqual(MiniAppDedup.removeDuplicates(in: context), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MiniApp>()).count, 2)
    }

    // MARK: - Refusals

    func testRandomJSONIsRejectedAsNotABackup() {
        let data = Data(#"{"hello":"world"}"#.utf8)
        XCTAssertThrowsError(try BackupService.restore(from: data, existingIds: [])) { error in
            XCTAssertEqual(error as? BackupService.RestoreError, .wrongFormat)
        }
    }

    func testGarbageIsRejectedAsUnreadable() {
        let data = Data("not json at all".utf8)
        XCTAssertThrowsError(try BackupService.restore(from: data, existingIds: [])) { error in
            XCTAssertEqual(error as? BackupService.RestoreError, .unreadable)
        }
    }

    /// An entry missing its html would otherwise insert an app that renders
    /// nothing; it should be dropped rather than restored broken.
    func testIncompleteEntriesAreSkipped() throws {
        let payload: [String: Any] = [
            "format": "aiity-backup",
            "version": 1,
            "miniApps": [
                ["name": "Kaputt", "emoji": "💥"],                       // no html
                ["name": "Heil", "emoji": "✅", "html": "<html>ok</html>"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let (result, restored) = try BackupService.restore(from: data, existingIds: [])
        XCTAssertEqual(result.addedApps, 1)
        XCTAssertEqual(restored.first?.name, "Heil")
    }
}
