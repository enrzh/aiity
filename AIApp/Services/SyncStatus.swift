import Foundation

/// Which storage mode the app actually came up in, so Settings can tell the
/// truth instead of implying iCloud sync that may not be running.
///
/// This is set once at launch by the container ladder in `AIAppApp` and never
/// changes for the lifetime of the process — a container cannot switch between
/// synced and local without being rebuilt.
@MainActor
final class SyncStatus: ObservableObject {
    static let shared = SyncStatus()

    enum Mode {
        /// CloudKit configuration accepted — records sync via the device's
        /// iCloud account. No sign-in of our own is involved.
        case synced
        /// The store opened, but without sync: no iCloud account, iCloud Drive
        /// off, or the entitlement isn't provisioned yet. Data is safe locally.
        case localOnly
        /// The previous store could not be read and was moved aside.
        case recovered
        /// Nothing on disk worked; this session is not being persisted.
        case inMemory
    }

    @Published private(set) var mode: Mode = .localOnly

    private init() {}

    func report(_ mode: Mode) {
        self.mode = mode
    }

    var title: String {
        switch mode {
        case .synced: return "iCloud aktiv"
        case .localOnly: return "Nur auf diesem Gerät"
        case .recovered: return "Neu angelegt"
        case .inMemory: return "Nicht gespeichert"
        }
    }

    var detail: String {
        switch mode {
        case .synced:
            return "Mini-Apps synchronisieren über deine Apple-ID. Kein Login in der App nötig."
        case .localOnly:
            return "Kein iCloud-Sync — melde dich in den iOS-Einstellungen bei iCloud an, oder aktiviere iCloud Drive. Deine Daten bleiben lokal erhalten."
        case .recovered:
            return "Der bisherige Datenspeicher war unlesbar und wurde zur Seite gelegt. Ein Backup kannst du unten einspielen."
        case .inMemory:
            return "Der Datenspeicher lässt sich nicht öffnen — Änderungen dieser Sitzung gehen beim Beenden verloren."
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
