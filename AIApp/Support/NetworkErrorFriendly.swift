import Foundation

/// Maps raw URL / API failures into short German strings users can act on.
enum NetworkErrorFriendly {
    static func message(for error: Error) -> String {
        if let pe = error as? ProviderError {
            return pe.localizedDescription
        }
        if let url = error as? URLError {
            switch url.code {
            case .networkConnectionLost:
                return String(localized: "Verbindung unterbrochen — WLAN/Mobilfunk prüfen und erneut senden. Bei langen Antworten: App im Vordergrund lassen.")
            case .notConnectedToInternet:
                return String(localized: "Kein Internet — Verbindung prüfen und erneut versuchen.")
            case .timedOut:
                return String(localized: "Zeitüberschreitung — Server brauchte zu lange (Abo/Cloud oft 1–3 Min. für Apps). Erneut senden, kürzere Anfrage, oder API-Key statt Abo.")
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return String(localized: "Server nicht erreichbar — IP/Port prüfen. Ist das iPhone im selben WLAN wie der Server, oder per Tailscale/VPN verbunden?")
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot:
                return String(localized: "TLS/Zertifikat abgelehnt — nutzt dein Gateway ein selbst-signiertes Zertifikat? Im LAN http:// statt https:// verwenden, oder ein vertrauenswürdiges Zertifikat (z. B. Tailscale Serve) einrichten.")
            case .cancelled:
                return "Anfrage abgebrochen."
            default:
                return "Netzwerkfehler: \(url.localizedDescription)"
            }
        }
        let text = error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("network connection was lost")
            || lower.contains("connection was lost")
            || (lower.contains("nsurlerrordomain") && lower.contains("-1005")) {
            return String(localized: "Verbindung unterbrochen — Netz prüfen und erneut senden.")
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return String(localized: "Zeitüberschreitung — erneut versuchen.")
        }
        return text
    }

    static func isTransient(_ error: Error) -> Bool {
        if let url = error as? URLError {
            switch url.code {
            case .networkConnectionLost, .timedOut, .notConnectedToInternet,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        let lower = error.localizedDescription.lowercased()
        return lower.contains("connection was lost") || lower.contains("timed out")
    }
}
