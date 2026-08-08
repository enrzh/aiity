import XCTest
import SwiftData
@testable import AIApp

/// The displayed sync state must track what CloudKit actually did, not what
/// the container ladder hoped at launch. `NSPersistentCloudKitContainer.Event`
/// has no public initializer, so these tests drive the internal
/// `note(_:)`/`noteAccountAvailability(_:)` seams the notification handlers
/// reduce into.
@MainActor
final class SyncStatusTests: XCTestCase {

    private func makeStatus(
        timeout: TimeInterval = 60,
        accountAvailable: Bool = true
    ) -> SyncStatus {
        SyncStatus(importWaitTimeout: timeout, accountCheck: { $0(accountAvailable) })
    }

    private func outcome(
        _ kind: SyncStatus.SyncEventOutcome.Kind,
        succeeded: Bool,
        error: String? = nil
    ) -> SyncStatus.SyncEventOutcome {
        SyncStatus.SyncEventOutcome(kind: kind, succeeded: succeeded, errorDescription: error)
    }

    // MARK: - Placeholder settling

    func testNonSyncedModesSettleImmediately() {
        for mode: SyncStatus.Mode in [.localOnly, .recovered, .inMemory] {
            let status = makeStatus()
            status.report(mode)
            XCTAssertTrue(status.initialImportComplete, "\(mode) has nothing to wait for")
        }
    }

    func testSyncedWaitsAndSettlesOnSuccessfulImport() {
        let status = makeStatus()
        status.report(.synced)
        XCTAssertFalse(status.initialImportComplete)

        status.note(outcome(.import, succeeded: true))
        XCTAssertTrue(status.initialImportComplete)
        XCTAssertNil(status.lastSyncError)
    }

    func testFailedImportDoesNotSettle() {
        let status = makeStatus()
        status.report(.synced)

        status.note(outcome(.import, succeeded: false, error: "Kontingent erschöpft"))
        XCTAssertFalse(
            status.initialImportComplete,
            "a FAILED import means the data has not arrived — settling would show a false empty state"
        )
        XCTAssertEqual(status.lastSyncError, "Kontingent erschöpft")
        XCTAssertTrue(status.subtitle.contains("Kontingent erschöpft"))

        // The next successful import both settles and clears the error.
        status.note(outcome(.import, succeeded: true))
        XCTAssertTrue(status.initialImportComplete)
        XCTAssertNil(status.lastSyncError)
    }

    func testExportAndSetupEventsFeedErrorWithoutSettlingImport() {
        let status = makeStatus()
        status.report(.synced)

        status.note(outcome(.setup, succeeded: false, error: "Setup fehlgeschlagen"))
        XCTAssertEqual(status.lastSyncError, "Setup fehlgeschlagen")
        XCTAssertFalse(status.initialImportComplete)

        status.note(outcome(.export, succeeded: false, error: "Export fehlgeschlagen"))
        XCTAssertEqual(status.lastSyncError, "Export fehlgeschlagen")
        XCTAssertFalse(status.initialImportComplete, "an export ending is not an import arriving")

        status.note(outcome(.export, succeeded: true))
        XCTAssertNil(status.lastSyncError, "a later success clears the surfaced error")
        XCTAssertFalse(status.initialImportComplete)
    }

    func testFailedEventWithoutDescriptionStillSurfacesSomething() {
        let status = makeStatus()
        status.report(.synced)
        status.note(outcome(.export, succeeded: false, error: nil))
        XCTAssertNotNil(status.lastSyncError)
    }

    func testTimeoutSettlesWhenNoImportEverEnds() async throws {
        let status = makeStatus(timeout: 0.2)
        status.report(.synced)
        XCTAssertFalse(status.initialImportComplete)

        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(status.initialImportComplete, "the placeholder must be bounded")
    }

    func testWaitUntilSettledReturnsOnceImportSucceeds() async {
        let status = makeStatus(timeout: 10)
        status.report(.synced)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            status.note(self.outcome(.import, succeeded: true))
        }
        await status.waitUntilInitialImportSettled()
        XCTAssertTrue(status.initialImportComplete)
    }

    // MARK: - Account availability

    func testMissingAccountDowngradesDisplayedModeAndSettles() async throws {
        let status = makeStatus(accountAvailable: false)
        status.report(.synced)
        // The account answer lands via a MainActor hop — give it a tick.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(status.mode, .synced, "the container really is CloudKit-configured")
        XCTAssertEqual(status.displayedMode, .localOnly, "but the UI must not claim active sync without an account")
        XCTAssertEqual(status.systemImage, "icloud.slash")
        XCTAssertTrue(status.initialImportComplete, "no account means no import is coming")
    }

    func testAccountReturningRestoresDisplayedMode() async throws {
        let status = makeStatus(accountAvailable: false)
        status.report(.synced)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(status.displayedMode, .localOnly)

        // What the .CKAccountChanged re-check reports after signing back in.
        status.noteAccountAvailability(true)
        XCTAssertEqual(status.displayedMode, .synced)
    }

    // MARK: - Local→synced catch-up marker

    func testCatchUpFlagArmsExactlyOnLocalToSyncedTransition() {
        let suite = "sync-transition-tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        SyncModeTransition.noteLaunch(mode: .localOnly, defaults: defaults)
        XCTAssertFalse(SyncModeTransition.consumePendingCatchUp(defaults: defaults))

        SyncModeTransition.noteLaunch(mode: .synced, defaults: defaults)
        XCTAssertTrue(SyncModeTransition.consumePendingCatchUp(defaults: defaults))
        XCTAssertFalse(SyncModeTransition.consumePendingCatchUp(defaults: defaults), "the flag is one-shot")

        // synced → synced does not re-arm.
        SyncModeTransition.noteLaunch(mode: .synced, defaults: defaults)
        XCTAssertFalse(SyncModeTransition.consumePendingCatchUp(defaults: defaults))

        // An in-memory launch persists nothing and must not disturb the
        // last REAL mode: local → (inMemory) → synced still arms.
        SyncModeTransition.noteLaunch(mode: .localOnly, defaults: defaults)
        SyncModeTransition.noteLaunch(mode: .inMemory, defaults: defaults)
        SyncModeTransition.noteLaunch(mode: .synced, defaults: defaults)
        XCTAssertTrue(SyncModeTransition.consumePendingCatchUp(defaults: defaults))
    }

    func testTouchAllRecordsBumpsInvisiblyAndPreservesOrder() throws {
        let container = try ModelContainer(
            for: MiniApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let older = MiniApp(name: "Alt", emoji: "🕰", html: "<html>a</html>")
        older.updatedAt = Date(timeIntervalSince1970: 100)
        let newer = MiniApp(name: "Neu", emoji: "✨", html: "<html>b</html>")
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        context.insert(older)
        context.insert(newer)
        try context.save()

        SyncModeTransition.touchAllRecords(in: context)

        XCTAssertEqual(older.updatedAt.timeIntervalSince1970, 100.001, accuracy: 0.0005)
        XCTAssertEqual(newer.updatedAt.timeIntervalSince1970, 200.001, accuracy: 0.0005)
        XCTAssertTrue(older.updatedAt < newer.updatedAt, "the +1 ms bump must never reorder the library")
    }
}
