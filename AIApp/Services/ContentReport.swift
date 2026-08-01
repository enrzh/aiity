import Foundation

/// Reporting objectionable model output.
///
/// App Review guideline 1.2 expects apps that display generated or
/// user-contributed content to offer a way to report it and to respond to
/// those reports. aiity shows whatever the user's chosen model returns, and
/// nobody here filters that in advance — so a report path is the honest
/// mechanism, not a checkbox.
///
/// There is no aiity server, which shapes the design: a report cannot be
/// "submitted" anywhere. It is composed on the device and the user sends it
/// themselves, seeing exactly what it contains first. That keeps the promise
/// the rest of the app makes — nothing leaves the device unless the user sends
/// it — instead of quietly opening a reporting endpoint.
enum ContentReport {

    /// Where reports go.
    ///
    /// Must exist and be read: guideline 1.2 asks for responses to reports,
    /// not just a form. Also published in the privacy policy, the Impressum
    /// and the App Store listing, so changing it means changing those too.
    static let contactAddress = "getaiityapp@gmail.com"

    enum Reason: String, CaseIterable, Identifiable {
        case hateful
        case sexual
        case violent
        case dangerous
        case falseInfo
        case other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hateful: return "Hass oder Beleidigung"
            case .sexual: return "Sexueller Inhalt"
            case .violent: return "Gewalt"
            case .dangerous: return "Gefährliche Anleitung"
            case .falseInfo: return "Falsche Angaben"
            case .other: return "Etwas anderes"
            }
        }
    }

    /// Everything the report will contain, rendered for the user to read
    /// BEFORE they send it. Pure, so what the sheet previews and what gets
    /// sent cannot drift apart.
    ///
    /// Deliberately narrow: the reported message, the model that produced it,
    /// and the app/OS version. Not the conversation, not the other messages,
    /// not the provider key, not the diagnostics record.
    static func body(
        message: ChatMessage,
        reason: Reason,
        note: String,
        provider: String,
        model: String,
        appVersion: String,
        systemVersion: String,
        at date: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("Gemeldeter Inhalt — aiity")
        lines.append("Grund:    \(reason.title)")
        lines.append("Zeit:     \(ISO8601DateFormatter().string(from: date))")
        lines.append("Modell:   \(provider)\(model.isEmpty ? "" : " · \(model)")")
        lines.append("App:      \(appVersion) · iOS \(systemVersion)")
        if let author = message.authorName {
            lines.append("Agent:    \(author)")
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            lines.append("")
            lines.append("Anmerkung:")
            lines.append(trimmedNote)
        }
        lines.append("")
        lines.append("--- Nachricht ---")
        lines.append(String(message.text.prefix(maxReportedCharacters)))
        if message.text.count > maxReportedCharacters {
            lines.append("[gekürzt — \(message.text.count) Zeichen insgesamt]")
        }
        return lines.joined(separator: "\n")
    }

    /// A pasted mini-app can be tens of thousands of characters; a mail body
    /// that long is rejected by some clients and unreadable in all of them.
    static let maxReportedCharacters = 4_000

    static func subject(for reason: Reason) -> String {
        "aiity — Meldung: \(reason.title)"
    }

    /// `mailto:` for the report. Returns nil only if the body cannot be
    /// percent-encoded, which cannot happen for text but is not worth
    /// force-unwrapping.
    static func mailURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = contactAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }
}
