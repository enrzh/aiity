import XCTest
@testable import AIApp

/// The `.aiityapp` envelope: encode → decode round-trip, every rejection
/// `decode` can produce, and the no-trust property of an import (fresh UUID,
/// no files, no consent anywhere near it). Pure value tests — nothing here
/// touches shared state, so no snapshot/restore machinery is needed.
final class MiniAppExportTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let data = try MiniAppExport.encode(
            name: "Haushaltsplan",
            emoji: "🧹",
            iconSymbol: "checklist",
            html: "<html><body>putzen</body></html>"
        )
        let envelope = try MiniAppExport.decode(data)
        XCTAssertEqual(envelope.formatVersion, MiniAppExport.formatVersion)
        XCTAssertEqual(envelope.name, "Haushaltsplan")
        XCTAssertEqual(envelope.emoji, "🧹")
        XCTAssertEqual(envelope.iconSymbol, "checklist")
        XCTAssertEqual(envelope.html, "<html><body>putzen</body></html>")
    }

    func testAMissingIconSymbolStaysNilThroughTheRoundTrip() throws {
        let data = try MiniAppExport.encode(
            name: "Ohne Icon", emoji: "✨", iconSymbol: nil, html: "<html>x</html>"
        )
        XCTAssertNil(try MiniAppExport.decode(data).iconSymbol)
    }

    /// The security property of import: a fresh UUID every time. Ids key
    /// consent grants and browser session stores, so honoring an id from the
    /// file would let a crafted file inherit an existing app's grants.
    func testImportMintsAFreshIdAndCarriesNoCompanionFiles() throws {
        let envelope = try MiniAppExport.decode(
            MiniAppExport.encode(name: "Quiz", emoji: "❓", iconSymbol: nil, html: "<html>q</html>")
        )
        let first = MiniAppExport.makeMiniApp(from: envelope)
        let second = MiniAppExport.makeMiniApp(from: envelope)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.filesJSON, "{}")
        XCTAssertEqual(first.html, "<html>q</html>")
    }

    // MARK: - Rejections

    func testGarbageIsUnreadable() {
        XCTAssertThrowsError(try MiniAppExport.decode(Data("kein json".utf8))) {
            XCTAssertEqual($0 as? MiniAppExport.ImportError, .unreadable)
        }
    }

    func testAForeignJSONObjectIsWrongFormat() {
        let foreign = Data(#"{"format":"aiity-backup","version":1}"#.utf8)
        XCTAssertThrowsError(try MiniAppExport.decode(foreign)) {
            XCTAssertEqual($0 as? MiniAppExport.ImportError, .wrongFormat)
        }
    }

    func testANewerFormatVersionIsRefusedNotGuessedAt() {
        let future = Data(#"{"formatVersion":2,"html":"<html>x</html>"}"#.utf8)
        XCTAssertThrowsError(try MiniAppExport.decode(future)) {
            XCTAssertEqual($0 as? MiniAppExport.ImportError, .unsupportedVersion)
        }
    }

    func testMissingHTMLIsRejected() {
        let empty = Data(#"{"formatVersion":1,"name":"Leer"}"#.utf8)
        XCTAssertThrowsError(try MiniAppExport.decode(empty)) {
            XCTAssertEqual($0 as? MiniAppExport.ImportError, .missingHTML)
        }
    }

    func testWhitespaceOnlyHTMLIsRejected() {
        let blank = Data(#"{"formatVersion":1,"html":"  \n  "}"#.utf8)
        XCTAssertThrowsError(try MiniAppExport.decode(blank)) {
            XCTAssertEqual($0 as? MiniAppExport.ImportError, .missingHTML)
        }
    }

    /// The size gate must fire on the raw byte count, BEFORE any parsing.
    func testOversizedDataIsRejected() {
        let oversized = Data(count: MiniAppExport.maxBytes + 1)
        XCTAssertThrowsError(try MiniAppExport.decode(oversized)) {
            XCTAssertEqual($0 as? MiniAppExport.ImportError, .tooLarge)
        }
    }

    func testEncodeRefusesAnAppWithEmptyHTML() {
        XCTAssertThrowsError(
            try MiniAppExport.encode(name: "Leer", emoji: "✨", iconSymbol: nil, html: "  ")
        ) {
            XCTAssertEqual($0 as? MiniAppExport.ImportError, .missingHTML)
        }
    }

    func testEncodeRefusesAnAppBeyondTheSizeCap() {
        let huge = "<html>" + String(repeating: "x", count: MiniAppExport.maxBytes) + "</html>"
        XCTAssertThrowsError(
            try MiniAppExport.encode(name: "Riesig", emoji: "🐘", iconSymbol: nil, html: huge)
        ) {
            XCTAssertEqual($0 as? MiniAppExport.ImportError, .tooLarge)
        }
    }

    // MARK: - File name

    func testFileNameStripsPathHostileCharacters() {
        XCTAssertEqual(MiniAppExport.fileName(for: "A/B:C"), "A-B-C.aiityapp")
    }

    func testFileNameFallsBackForAnEmptyName() {
        XCTAssertEqual(MiniAppExport.fileName(for: "   "), "Mini-App.aiityapp")
    }
}
