import Foundation

/// What a mini-app is allowed to do outside pure offline UI.
/// Declared in HTML: `<!-- capability: offline|network|browser -->`
enum MiniAppCapability: String, Codable, Equatable {
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
    var csp: String {
        switch self {
        case .offline:
            return "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:;"
        case .network:
            // Allow XHR/fetch + images over https; no frames (not a full browser).
            return "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: https: http:; font-src data: https:; media-src data: https: http:; connect-src https: http:; worker-src 'none'; object-src 'none';"
        case .browser:
            // Research-style apps: frames + navigation + fetch.
            return "default-src 'none'; style-src 'unsafe-inline' https: http:; script-src 'unsafe-inline' https: http:; img-src data: https: http:; font-src data: https: http:; media-src data: https: http:; connect-src https: http:; frame-src https: http:; child-src https: http:; worker-src 'none'; object-src 'none';"
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
