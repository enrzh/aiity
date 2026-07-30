import Foundation
import Combine
import UIKit

/// Lightweight user prefs that are not part of provider settings.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private static let keepScreenKey = "prefs.keepScreenAwakeWhileBuilding.v1"
    static let allowLocalToolsKey = "prefs.allowLocalTools.v1"
    static let iCloudSyncKey = "prefs.iCloudSync.v1"

    /// Whether the SwiftData store is opened with CloudKit. Read once at launch
    /// by the container ladder — a container cannot switch between synced and
    /// local while running, so changing this only takes effect on next start.
    /// Turning it off does not delete anything: the same local store is opened,
    /// it simply stops replicating.
    @Published var iCloudSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(iCloudSyncEnabled, forKey: Self.iCloudSyncKey) }
    }

    /// Non-isolated read for the container ladder, which runs before any actor
    /// context exists.
    nonisolated static var iCloudSyncPreference: Bool {
        UserDefaults.standard.object(forKey: iCloudSyncKey) as? Bool ?? true
    }

    /// When true, disable idle timer while the agent is busy (chat/build running).
    @Published var keepScreenAwakeWhileBuilding: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenAwakeWhileBuilding, forKey: Self.keepScreenKey)
            ScreenWake.shared.refresh()
        }
    }

    /// When true, on-device / LAN models also get the web tools (web_search /
    /// fetch_url). Off by default — tiny models invent fake tool calls; enable
    /// only for a capable local model (Qwen3 4B+).
    @Published var allowLocalTools: Bool {
        didSet { UserDefaults.standard.set(allowLocalTools, forKey: Self.allowLocalToolsKey) }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.keepScreenKey) == nil {
            // Default off — users opt in (saves battery). didSet not called from init.
            keepScreenAwakeWhileBuilding = false
        } else {
            keepScreenAwakeWhileBuilding = UserDefaults.standard.bool(forKey: Self.keepScreenKey)
        }
        allowLocalTools = UserDefaults.standard.bool(forKey: Self.allowLocalToolsKey)
        iCloudSyncEnabled = Self.iCloudSyncPreference
    }
}

/// Central place for idle-timer control so Live Activity + settings stay in sync.
@MainActor
enum ScreenWake {
    static let shared = ScreenWakeBox()
}

@MainActor
final class ScreenWakeBox {
    private var agentBusy = false

    func setAgentBusy(_ busy: Bool) {
        agentBusy = busy
        refresh()
    }

    /// Recompute idle timer from current agent state + preference.
    func refresh() {
        let keep = agentBusy && AppPreferences.shared.keepScreenAwakeWhileBuilding
        UIApplication.shared.isIdleTimerDisabled = keep
    }
}
