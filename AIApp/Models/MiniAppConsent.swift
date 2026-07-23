import Foundation

/// Remembers which mini-apps the user allowed to reach the network. A generated
/// app can *declare* `network`/`browser` capability, but that only grants a
/// relaxed CSP after the user consents on first open — the AI can't silently
/// give an app internet access.
enum MiniAppConsent {
    private static let key = "miniapp-consent-v1"  // [appId: capabilityRawValue]

    static func granted(appId: String) -> MiniAppCapability? {
        guard let map = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
              let raw = map[appId] else { return nil }
        return MiniAppCapability(rawValue: raw)
    }

    static func allow(appId: String, capability: MiniAppCapability) {
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        map[appId] = capability.rawValue
        UserDefaults.standard.set(map, forKey: key)
    }

    /// Offline apps always run; a non-offline app is allowed only if the user
    /// previously granted it a non-offline capability.
    static func isAllowed(appId: String, declared: MiniAppCapability) -> Bool {
        if declared == .offline { return true }
        guard let granted = granted(appId: appId) else { return false }
        return granted != .offline
    }
}
