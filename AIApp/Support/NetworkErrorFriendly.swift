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
                return "Verbindung unterbrochen — WLAN/Mobilfunk prüfen und erneut senden. Bei langen Antworten: App im Vordergrund lassen."
            case .notConnectedToInternet:
                return "Kein Internet — Verbindung prüfen und erneut versuchen."
            case .timedOut:
                return "Zeitüberschreitung — Server brauchte zu lange (Abo/Cloud oft 1–3 Min. für Apps). Erneut senden, kürzere Anfrage, oder API-Key statt Abo."
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "Server nicht erreichbar — Host/Base-URL und Netz prüfen."
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "Sichere Verbindung fehlgeschlagen (TLS). Datum/Uhrzeit und Zertifikat prüfen."
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
            return "Verbindung unterbrochen — Netz prüfen und erneut senden."
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Zeitüberschreitung — erneut versuchen."
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
