import Foundation

/// What a mini-app is allowed to do outside pure offline UI.
/// Declared in HTML: `<!-- capability: offline|network|browser -->`
enum MiniAppCapability: String, Codable, Equatable, CaseIterable {
    case offline
    case network
    case browser

    static func from(html: String) -> MiniAppCapability {
        let lower = html.lowercased()
        if let range = lower.range(of: #"<!--\s*capability:\s*([a-z]+)\s*-->"#, options: .regularExpression) {
            let slice = String(lower[range])
            if slice.contains("browser") { return .browser }
            if slice.contains("network") { return .network }
        }
        // Heuristic: explicit fetch/XHR intent in comments only — never auto-upgrade.
        return .offline
    }

    /// CSP string injected into the mini-app document.
    var csp: String { csp(allowedHosts: []) }

    /// A host grant is deliberately host-scoped and only expands HTTPS sources;
    /// public-target validation remains a separate native gate on every hop.
    func csp(allowedHosts: Set<String>) -> String {
        let origins = allowedHosts
            .compactMap(NetworkTargetValidator.normalizeHost)
            .sorted()
            .map { "https://\($0)" }
        let connect = origins.isEmpty ? "'none'" : origins.joined(separator: " ")
        let script = (["'unsafe-inline'"] + origins).joined(separator: " ")
        let resources = (["data:"] + origins).joined(separator: " ")
        let frames = origins.isEmpty ? "'none'" : origins.joined(separator: " ")
        switch self {
        case .offline:
            return "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:;"
        case .network:
            return "default-src 'none'; style-src 'unsafe-inline'; script-src \(script); img-src \(resources); font-src \(resources); media-src \(resources); connect-src \(connect); worker-src 'none'; object-src 'none';"
        case .browser:
            return "default-src 'none'; style-src \(script); script-src \(script); img-src \(resources); font-src \(resources); media-src \(resources); connect-src \(connect); frame-src \(frames); child-src \(frames); worker-src 'none'; object-src 'none';"
        }
    }

    /// Privilege ordering: offline < network < browser. Consent for a lower tier
    /// must NOT satisfy a request for a higher tier (no silent escalation).
    var rank: Int {
        switch self {
        case .offline: return 0
        case .network: return 1
        case .browser: return 2
        }
    }

    var allowsTopLevelNavigation: Bool {
        self == .browser
    }

    var allowsNetworkFetch: Bool {
        self != .offline
    }

    var label: String {
        switch self {
        case .offline: return "Offline"
        case .network: return "Netzwerk"
        case .browser: return "Browser"
        }
    }
}

/// Per-app capabilities the user consents to individually, OUTSIDE the
/// offline/network/browser ladder. Deliberately not a case of
/// `MiniAppCapability`: a tier grant is a single, replaceable value with a rank
/// ordering, and folding e.g. notifications into it would make granting them
/// silently overwrite (or be overwritten by) the app's network tier. A tier
/// grant never implies one of these and one of these never moves an app up the
/// ladder.
enum MiniAppAuxCapability: String, CaseIterable {
    /// `window.aiity.notifications` — schedule local notifications.
    case notifications
}
