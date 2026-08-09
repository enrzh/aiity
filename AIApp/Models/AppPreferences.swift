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
    static let smartSuggestionsKey = "prefs.smartSuggestions.v1"
    static let deviceToolsKey = "prefs.deviceTools.v1"
    private static let chatModeKey = "prefs.chatMode.v1"
    private static let appearanceKey = "prefs.appearance.v1"

    /// Light/dark/system, independent of the device setting.
    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    /// How much the agent asks before acting. Sticky across launches — a user
    /// who wants to be asked wants that every time, not until the next restart.
    @Published var chatMode: ChatMode {
        didSet { UserDefaults.standard.set(chatMode.rawValue, forKey: Self.chatModeKey) }
    }

    nonisolated static var storedChatMode: ChatMode {
        ChatMode(rawValue: UserDefaults.standard.string(forKey: chatModeKey) ?? "") ?? .auto
    }

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

    /// Whether the empty chat may ask the user's own cloud provider for a
    /// couple of fresh mini-app ideas. On by default, but only ever reachable
    /// with an explicitly chosen model on an API-key account — see
    /// `ChatSuggestionService.isEligible`. Costs at most one tiny completion
    /// per day; turning it off makes the chips fully static again.
    @Published var smartSuggestions: Bool {
        didSet { UserDefaults.standard.set(smartSuggestions, forKey: Self.smartSuggestionsKey) }
    }

    /// Non-isolated read for the service, which resolves the gate off the main
    /// actor's published state.
    nonisolated static var smartSuggestionsEnabled: Bool {
        UserDefaults.standard.object(forKey: smartSuggestionsKey) as? Bool ?? true
    }

    /// Master switch for the device-data agent tools (reminders, calendar,
    /// shared files). Defaults to ON, which grants exactly nothing: the tools
    /// are additionally gated on an iOS authorization the user has to hand out
    /// themselves, so "on" only means "don't hide the feature". Turning it off
    /// withholds the tools even from a model whose permissions are granted —
    /// without revoking anything in iOS Settings.
    @Published var deviceToolsEnabled: Bool {
        didSet { UserDefaults.standard.set(deviceToolsEnabled, forKey: Self.deviceToolsKey) }
    }

    nonisolated static var deviceToolsPreference: Bool {
        UserDefaults.standard.object(forKey: deviceToolsKey) as? Bool ?? true
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.keepScreenKey) == nil {
            // Default off — users opt in (saves battery). didSet not called from init.
            keepScreenAwakeWhileBuilding = false
        } else {
            keepScreenAwakeWhileBuilding = UserDefaults.standard.bool(forKey: Self.keepScreenKey)
        }
        allowLocalTools = UserDefaults.standard.bool(forKey: Self.allowLocalToolsKey)
        smartSuggestions = Self.smartSuggestionsEnabled
        deviceToolsEnabled = Self.deviceToolsPreference
        iCloudSyncEnabled = Self.iCloudSyncPreference
        chatMode = Self.storedChatMode
        appearance = AppAppearance(
            rawValue: UserDefaults.standard.string(forKey: Self.appearanceKey) ?? ""
        ) ?? .system
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
