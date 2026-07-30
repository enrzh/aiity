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

    /// Forget a deleted app's grant, so a future app that happens to reuse the
    /// id does not silently inherit permission the user never gave it.
    static func revoke(appId: String) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map.removeValue(forKey: appId)
        UserDefaults.standard.set(map, forKey: key)
    }

    /// Stable per-content id for an unsaved chat preview. Previews used to share
    /// the constant id "preview", so consenting one network app granted network
    /// to every later preview draft. Deterministic djb2 (NOT String.hashValue,
    /// which is randomized per process and unstable across launches).
    static func previewId(html: String) -> String {
        var h: UInt64 = 5381
        for b in html.utf8 { h = (h &* 33) &+ UInt64(b) }
        return "preview-" + String(h, radix: 16)
    }

    static func allow(appId: String, capability: MiniAppCapability) {
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        map[appId] = capability.rawValue
        UserDefaults.standard.set(map, forKey: key)
    }

    /// Offline apps always run; a non-offline app is allowed only if the user
    /// previously granted it a capability at least as privileged as the one
    /// declared. A `network` grant does NOT satisfy a `browser` app (an edit that
    /// escalates the tier must re-prompt), closing silent capability escalation.
    static func isAllowed(appId: String, declared: MiniAppCapability) -> Bool {
        if declared == .offline { return true }
        guard let granted = granted(appId: appId) else { return false }
        return granted.rank >= declared.rank
    }
}
