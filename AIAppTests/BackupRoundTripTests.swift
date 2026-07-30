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
