import Foundation
import Combine
import UIKit

/// Lightweight user prefs that are not part of provider settings.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private static let keepScreenKey = "prefs.keepScreenAwakeWhileBuilding.v1"

    /// When true, disable idle timer while the agent is busy (chat/build running).
    @Published var keepScreenAwakeWhileBuilding: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenAwakeWhileBuilding, forKey: Self.keepScreenKey)
            ScreenWake.shared.refresh()
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.keepScreenKey) == nil {
            // Default off — users opt in (saves battery). didSet not called from init.
            keepScreenAwakeWhileBuilding = false
        } else {
            keepScreenAwakeWhileBuilding = UserDefaults.standard.bool(forKey: Self.keepScreenKey)
        }
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
