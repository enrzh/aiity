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

    /// A host grant is deliberately host-scoped and allows both web schemes;
    /// public-target validation remains a separate native gate on every hop.
    func csp(allowedHosts: Set<String>) -> String {
        let origins = allowedHosts.sorted().flatMap { ["http://\($0)", "https://\($0)"] }
        let connect = origins.isEmpty ? "'none'" : origins.joined(separator: " ")
        switch self {
        case .offline:
            return "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:;"
        case .network:
            return "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: https:; font-src data: https:; media-src data: https:; connect-src \(connect); worker-src 'none'; object-src 'none';"
        case .browser:
            return "default-src 'none'; style-src 'unsafe-inline' https:; script-src 'unsafe-inline' https:; img-src data: https:; font-src data: https:; media-src data: https:; connect-src \(connect); frame-src https:; child-src https:; worker-src 'none'; object-src 'none';"
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
