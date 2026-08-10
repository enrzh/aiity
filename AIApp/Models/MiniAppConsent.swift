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

    /// Every grant the user has made, keyed by app id.
    ///
    /// Read by `MiniAppSessionStoreSweep`, which needs the COMPLETE list of ids
    /// that could own a persistent cookie jar: the runner only picks a
    /// persistent `WKWebsiteDataStore` when the grant here is `.browser`, so an
    /// id absent from this map can have no store — and chat previews, which
    /// have no library record at all, appear nowhere else.
    static func grants() -> [String: MiniAppCapability] {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return map.compactMapValues(MiniAppCapability.init(rawValue:))
    }

    /// Forget a deleted app's grant, so a future app that happens to reuse the
    /// id does not silently inherit permission the user never gave it.
    ///
    /// Two callers, and both are needed. `LibraryView`'s delete alert covers
    /// the delete the user performs HERE; `MiniAppSessionStoreSweep.run` covers
    /// every disappearance that alert never sees — above all a mini-app deleted
    /// on ANOTHER device, whose record vanishes through CloudKit mirroring with
    /// no alert to run. Without the second caller the grant outlives the record
    /// and silently re-arms if a record with the same UUID ever returns.
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
