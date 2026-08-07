import CoreData
import Foundation

/// Which storage mode the app actually came up in, so Settings can tell the
/// truth instead of implying iCloud sync that may not be running.
///
/// The storage mode is set once at launch by the container ladder in
/// `AIAppApp` and never changes for the lifetime of the process — a container
/// cannot switch between synced and local without being rebuilt.
@MainActor
final class SyncStatus: ObservableObject {
    static let shared = SyncStatus()

    enum Mode {
        /// CloudKit configuration accepted — records sync via the device's
        /// iCloud account. No sign-in of our own is involved.
        case synced
        /// The store opened, but without sync: the user switched iCloud off, no
        /// iCloud account, iCloud Drive off, or the entitlement isn't
        /// provisioned yet. Data is safe locally either way.
        case localOnly
        /// The previous store could not be read and was moved aside.
        case recovered
        /// Nothing on disk worked; this session is not being persisted.
        case inMemory
    }

    @Published private(set) var mode: Mode = .localOnly

    /// `mode == .synced` only means CloudKit accepted the configuration when
    /// the store opened — that says nothing about whether records already on
    /// other devices have actually arrived yet. The first import after a
    /// fresh install or a new device commonly takes real time, and until it
    /// finishes an empty on-disk store and a store that is simply still
    /// waiting on iCloud look IDENTICAL to a plain `@Query`. Without this,
    /// "iCloud is on but my apps didn't come back" reads as sync being
    /// broken, when it is usually just not finished yet.
    ///
    /// `true` once CloudKit's own import-finished signal has fired, once we
    /// give up waiting (see `importWaitTimeout`), or immediately when sync
    /// was never active in the first place — there is nothing to wait for.
    @Published private(set) var initialImportComplete = true

    /// How long to treat "no apps yet" as ambiguous before showing the
    /// ordinary empty state anyway. Generous on purpose: a large CloudKit
    /// import over a slow connection can take a while, and showing "syncing"
    /// too briefly defeats the point, but it must still end — a permanent
    /// spinner because the notification never arrives (sync disabled
    /// mid-import, an edge case CloudKit doesn't cover) would be worse than
    /// the bug this exists to fix.
    private static let importWaitTimeout: TimeInterval = 20

    private var importObserver: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?

    private init() {}

    func report(_ mode: Mode) {
        self.mode = mode
        #if DEBUG
        // Which rung of the container ladder we landed on is otherwise only
        // visible by opening Settings on the device.
        print("AIITY-STORE \(mode)")
        #endif

        guard mode == .synced else {
            // Nothing to import if we are not syncing at all.
            initialImportComplete = true
            return
        }
        initialImportComplete = false
        watchForInitialImport()
    }

    /// `NSPersistentCloudKitContainer.eventChangedNotification` is a plain
    /// NotificationCenter broadcast — SwiftData does not expose the
    /// underlying CloudKit container as public API, but it still posts this
    /// same notification under the hood, so a global observer sees it
    /// without needing a reference to the container itself.
    private func watchForInitialImport() {
        importObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event,
                event.type == .import,
                event.endDate != nil
            else { return }
            Task { @MainActor in self?.markImportSettled() }
        }

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.importWaitTimeout))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.markImportSettled() }
        }
    }

    private func markImportSettled() {
        guard !initialImportComplete else { return }
        initialImportComplete = true
        if let importObserver {
            NotificationCenter.default.removeObserver(importObserver)
            self.importObserver = nil
        }
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    var title: String {
        switch mode {
        case .synced: return String(localized: "iCloud aktiv")
        case .localOnly: return String(localized: "Nur auf diesem Gerät")
        case .recovered: return "Neu angelegt"
        case .inMemory: return "Nicht gespeichert"
        }
    }

    var detail: String {
        switch mode {
        case .synced:
            return String(localized: "Mini-Apps synchronisieren über deine Apple-ID. Kein Login in der App nötig.")
        case .localOnly:
            return AppPreferences.iCloudSyncPreference
                ? String(localized: "Kein iCloud-Sync — melde dich in den iOS-Einstellungen bei iCloud an, oder aktiviere iCloud Drive. Deine Daten bleiben lokal erhalten.")
                : String(localized: "iCloud ist ausgeschaltet. Deine Mini-Apps bleiben vollständig auf diesem Gerät.")
        case .recovered:
            return String(localized: "Der bisherige Datenspeicher war unlesbar und wurde zur Seite gelegt. Ein Backup kannst du unten einspielen.")
        case .inMemory:
            return String(localized: "Der Datenspeicher lässt sich nicht öffnen — Änderungen dieser Sitzung gehen beim Beenden verloren.")
        }
    }

    var systemImage: String {
        switch mode {
        case .synced: return "checkmark.icloud"
        case .localOnly: return "icloud.slash"
        case .recovered: return "exclamationmark.triangle"
        case .inMemory: return "exclamationmark.octagon"
        }
    }

    var isHealthy: Bool {
        mode == .synced || mode == .localOnly
    }
}
