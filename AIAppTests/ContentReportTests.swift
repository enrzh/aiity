import XCTest
@testable import AIApp

/// Reporting objectionable model output — App Review guideline 1.2.
///
/// The property that matters most here is not that a report can be sent, but
/// that it contains ONLY what the user was shown it would contain. The app's
/// whole claim is that nothing leaves the device unless the user sends it, and
/// a reporting flow is the one place that deliberately sends something.
final class ContentReportTests: XCTestCase {

    private func report(
        _ message: ChatMessage,
        reason: ContentReport.Reason = .hateful,
        note: String = ""
    ) -> String {
        ContentReport.body(
            message: message, reason: reason, note: note,
            provider: "anthropic", model: "claude-sonnet-4-5",
            appVersion: "0.6.0", systemVersion: "27.0",
            at: Date(timeIntervalSince1970: 770_000_000)
        )
    }

    func testTheReportCarriesTheMessageAndTheContextNeededToActOnIt() {
        let body = report(ChatMessage(role: .assistant, text: "etwas Verletzendes"))
        XCTAssertTrue(body.contains("etwas Verletzendes"))
        XCTAssertTrue(body.contains("Hass oder Beleidigung"))
        XCTAssertTrue(body.contains("anthropic · claude-sonnet-4-5"))
        XCTAssertTrue(body.contains("0.6.0"))
    }

    func testTheAgentNameIsIncludedWhenThereIsOne() {
        let body = report(ChatMessage(role: .assistant, text: "x", authorName: "Kritiker"))
        XCTAssertTrue(body.contains("Kritiker"))
    }

    /// The sheet shows the body and then sends that same string. If the two
    /// could differ, the preview would be a lie — so the builder is pure and
    /// both call sites use it.
    func testTheBodyIsDeterministic() {
        let message = ChatMessage(role: .assistant, text: "gleich")
        XCTAssertEqual(report(message), report(message))
    }

    /// A reported mini-app answer can be tens of thousands of characters. Mail
    /// clients reject bodies that long, and nobody reads them.
    func testAnEnormousMessageIsTruncatedAndSaysSo() {
        let huge = String(repeating: "z", count: 50_000)
        let body = report(ChatMessage(role: .assistant, text: huge))
        XCTAssertLessThan(body.count, ContentReport.maxReportedCharacters + 600)
        XCTAssertTrue(body.contains("gekürzt"))
        XCTAssertTrue(body.contains("50000"))
    }

    func testAnOptionalNoteIsIncludedAndAnEmptyOneIsNot() {
        let message = ChatMessage(role: .assistant, text: "x")
        XCTAssertTrue(report(message, note: "kam unaufgefordert").contains("kam unaufgefordert"))
        XCTAssertFalse(report(message, note: "   ").contains("Anmerkung"))
    }

    /// Everything a user was NOT told would be sent must be absent. This is the
    /// test that would fail first if someone later "helpfully" attached the
    /// conversation or the diagnostics record.
    func testTheReportContainsNothingBeyondTheReportedMessage() {
        let body = report(ChatMessage(role: .assistant, text: "die gemeldete Zeile"))
        for leak in ["sk-", "Bearer", "apiKey", "keychain", "chat-threads"] {
            XCTAssertFalse(body.lowercased().contains(leak.lowercased()), leak)
        }
        // One message, not a transcript: exactly one message section.
        XCTAssertEqual(body.components(separatedBy: "--- Nachricht ---").count - 1, 1)
    }

    func testEveryReasonIsLabelledAndStable() {
        XCTAssertEqual(ContentReport.Reason.allCases.count, 6)
        for reason in ContentReport.Reason.allCases {
            XCTAssertFalse(reason.title.isEmpty, reason.rawValue)
            XCTAssertTrue(ContentReport.subject(for: reason).contains(reason.title))
        }
    }

    /// Guideline 1.2 asks for a contact that is actually reachable, and the
    /// same address is published in the privacy policy.
    func testTheContactAddressIsOnOurOwnDomain() {
        XCTAssertTrue(ContentReport.contactAddress.hasSuffix("@aiity.de"),
                      ContentReport.contactAddress)
    }

    /// A body with newlines, umlauts and an ampersand must survive being put
    /// into a mailto: URL — losing it would send an empty report.
    func testTheMailURLEncodesAwkwardBodies() throws {
        let body = "Zeile 1\nZeile 2 & mehr\nÜmlaute: äöü"
        let url = try XCTUnwrap(ContentReport.mailURL(subject: "aiity — Meldung", body: body))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.contains(ContentReport.contactAddress))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "body" }?.value, body)
    }
}
