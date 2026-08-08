import CloudKit
import CoreData
import Foundation

/// Which storage mode the app actually came up in, so Settings can tell the
/// truth instead of implying iCloud sync that may not be running.
///
/// The storage mode is set once at launch by the container ladder in
/// `AIAppApp` and never changes for the lifetime of the process — a container
/// cannot switch between synced and local without being rebuilt. What CAN
/// change while running is whether that mode is actually working: the iCloud
/// account can disappear (sign-out mid-run, and `ModelContainer` init is not
/// guaranteed to throw when there was no account to begin with), and any
/// setup/import/export event can fail. Both are tracked here and reflected in
/// the displayed state instead of a permanent, optimistic "iCloud aktiv".
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

    /// What a single ended CloudKit mirroring event boiled down to. The real
    /// `NSPersistentCloudKitContainer.Event` has no public initializer, so the
    /// notification handler reduces it to this and the reducing logic stays
    /// unit-testable without CloudKit running.
    struct SyncEventOutcome {
        enum Kind {
            case setup, `import`, export, unknown

            init(_ type: NSPersistentCloudKitContainer.EventType) {
                switch type {
                case .setup: self = .setup
                case .import: self = .import
                case .export: self = .export
                @unknown default: self = .unknown
                }
            }
        }

        let kind: Kind
        let succeeded: Bool
        let errorDescription: String?
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
    /// `true` once CloudKit reports a SUCCESSFUL finished import (a failed
    /// one settles nothing — the data has not arrived), once we give up
    /// waiting (see `importWaitTimeout`), once the account turns out to be
    /// unavailable (nothing will arrive), or immediately when sync was never
    /// active in the first place — there is nothing to wait for.
    @Published private(set) var initialImportComplete = true

    /// Human-readable description of the most recent FAILED CloudKit event
    /// (setup, import or export — quota, auth, network), cleared again by the
    /// next successful one. Surfaced in Settings so "iCloud aktiv" cannot
    /// stand unqualified while every export quietly fails.
    @Published private(set) var lastSyncError: String?

    /// Whether the device currently appears to have a usable iCloud account.
    /// Checked when sync starts and re-checked on `.CKAccountChanged`, so
    /// signing out mid-run downgrades the displayed state instead of leaving
    /// a stale "iCloud aktiv". Errs toward `true`: only a definitive
    /// no-account/restricted answer downgrades — a transient CloudKit hiccup
    /// must not flip the UI to "not syncing".
    @Published private(set) var accountAvailable = true

    /// How long to treat "no apps yet" as ambiguous before showing the
    /// ordinary empty state anyway. Generous on purpose: a large CloudKit
    /// import over a slow connection can take a while, and showing "syncing"
    /// too briefly defeats the point, but it must still end — a permanent
    /// spinner because the notification never arrives (sync disabled
    /// mid-import, an edge case CloudKit doesn't cover) would be worse than
    /// the bug this exists to fix.
    private let importWaitTimeout: TimeInterval

    /// Injectable so tests can answer without any iCloud machinery.
    private let accountCheck: (@escaping (Bool) -> Void) -> Void

    private var timeoutTask: Task<Void, Never>?
    private var monitoring = false
    private let observers = ObserverBag()

    init(
        importWaitTimeout: TimeInterval = 20,
        accountCheck: @escaping (@escaping (Bool) -> Void) -> Void = SyncStatus.checkCloudKitAccount
    ) {
        self.importWaitTimeout = importWaitTimeout
        self.accountCheck = accountCheck
    }

    /// `ubiquityIdentityToken` is nil when no iCloud account is signed in or
    /// iCloud Drive is off — exactly the preconditions
    /// `NSPersistentCloudKitContainer` needs before it mirrors anything.
    /// Deliberately NOT `CKContainer.accountStatus`: CKContainer raises an
    /// ObjC exception (uncatchable from Swift) in any process without the
    /// icloud-services entitlement — which includes every unsigned test host,
    /// and did crash the whole suite at launch — whereas the token is safe to
    /// read anywhere.
    nonisolated static func checkCloudKitAccount(_ completion: @escaping (Bool) -> Void) {
        completion(FileManager.default.ubiquityIdentityToken != nil)
    }

    func report(_ mode: Mode) {
        self.mode = mode
        if self === SyncStatus.shared {
            // Only the real launch records the mode transition — test
            // instances must not arm the catch-up flag in the host app.
            SyncModeTransition.noteLaunch(mode: mode)
        }
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
        startMonitoring()
        refreshAccountStatus()
        armImportTimeout()
    }

    /// `NSPersistentCloudKitContainer.eventChangedNotification` is a plain
    /// NotificationCenter broadcast — SwiftData does not expose the
    /// underlying CloudKit container as public API, but it still posts this
    /// same notification under the hood, so a global observer sees it
    /// without needing a reference to the container itself. The observer
    /// stays installed past the initial import: later export/import failures
    /// (quota, auth) feed `lastSyncError`.
    private func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true

        observers.add(NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event,
                event.endDate != nil
            else { return }
            let outcome = SyncEventOutcome(
                kind: SyncEventOutcome.Kind(event.type),
                succeeded: event.succeeded,
                errorDescription: event.error?.localizedDescription
            )
            Task { @MainActor in self?.note(outcome) }
        })

        // Both account-change signals: CloudKit's (posted while the mirroring
        // machinery is live) and Foundation's (matches the ubiquity token the
        // default check reads). Either one triggers a re-check.
        for name in [Notification.Name.CKAccountChanged, .NSUbiquityIdentityDidChange] {
            observers.add(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshAccountStatus() }
            })
        }
    }

    /// Reduce one ended CloudKit event into displayed state. Internal so the
    /// success/failure paths are testable without synthesizing the
    /// un-constructible `NSPersistentCloudKitContainer.Event`.
    func note(_ outcome: SyncEventOutcome) {
        if outcome.succeeded {
            lastSyncError = nil
        } else {
            lastSyncError = outcome.errorDescription ?? String(localized: "Unbekannter Sync-Fehler")
        }
        // Only a SUCCESSFUL import settles the placeholder — a failed one
        // means the data did NOT arrive, and settling on it would show the
        // empty state as if there were nothing to sync. The timeout still
        // bounds the wait when imports keep failing.
        if outcome.kind == .import, outcome.succeeded {
            markImportSettled()
        }
    }

    private func refreshAccountStatus() {
        accountCheck { [weak self] available in
            Task { @MainActor in self?.noteAccountAvailability(available) }
        }
    }

    /// Internal for tests (the injected check also lands here).
    func noteAccountAvailability(_ available: Bool) {
        accountAvailable = available
        if !available {
            // No account: no import is coming, stop showing the placeholder.
            markImportSettled()
        }
    }

    private func armImportTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, importWaitTimeout] in
            try? await Task.sleep(for: .seconds(importWaitTimeout))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.markImportSettled() }
        }
    }

    private func markImportSettled() {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard !initialImportComplete else { return }
        initialImportComplete = true
    }

    /// Suspends until the initial-import placeholder is settled (successful
    /// import, timeout, or no account). Used by backup import: restoring
    /// while the first import is still in flight can insert a record whose
    /// UUID is about to arrive from iCloud as well — a duplicate CloudKit
    /// itself can never dedup. Bounded by `importWaitTimeout`.
    func waitUntilInitialImportSettled() async {
        while !initialImportComplete {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// What the UI should claim. `mode` stays what the container ladder
    /// reported (the store really is CloudKit-configured), but a synced store
    /// without an iCloud account is not syncing anything — show it as local.
    var displayedMode: Mode {
        (mode == .synced && !accountAvailable) ? .localOnly : mode
    }

    var title: String {
        switch displayedMode {
        case .synced: return String(localized: "iCloud aktiv")
        case .localOnly: return String(localized: "Nur auf diesem Gerät")
        case .recovered: return "Neu angelegt"
        case .inMemory: return "Nicht gespeichert"
        }
    }

    var detail: String {
        switch displayedMode {
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

    /// The Settings row subtitle: the last sync failure when there is one,
    /// otherwise the ordinary mode description.
    var subtitle: String {
        if let lastSyncError {
            return String(localized: "Sync-Problem: \(lastSyncError)")
        }
        return detail
    }

    var systemImage: String {
        if displayedMode == .synced && lastSyncError != nil {
            return "exclamationmark.icloud"
        }
        switch displayedMode {
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

/// Removes NotificationCenter observers when the owner deallocates — needed
/// because test instances of `SyncStatus` come and go, while the app-wide
/// singleton never does.
private final class ObserverBag {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
