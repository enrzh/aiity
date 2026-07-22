import XCTest
@testable import AIApp

final class MiniAppBundleTests: XCTestCase {

    func testExtractSingleHTML() {
        let text = """
        Here:
        ```html
        <!DOCTYPE html><html><head><title>Hi</title></head><body>x</body></html>
        ```
        """
        let bundle = MiniAppBundleParser.extract(from: text)
        XCTAssertEqual(bundle?.name, "Hi")
        XCTAssertTrue(bundle?.files.isEmpty == true)
        XCTAssertTrue(bundle?.html.contains("<title>Hi</title>") == true)
    }

    func testExtractMultiFileAndBundle() {
        let text = """
        ```html
        <!DOCTYPE html><html><head><title>Todo</title>
        <!-- emoji: ✅ -->
        </head><body><h1>Todo</h1></body></html>
        ```
        ```css:style.css
        body { color: red; }
        ```
        ```js:app.js
        console.log(1);
        ```
        """
        let bundle = MiniAppBundleParser.extract(from: text)
        XCTAssertEqual(bundle?.name, "Todo")
        XCTAssertEqual(bundle?.files["style.css"], "body { color: red; }")
        XCTAssertEqual(bundle?.files["app.js"], "console.log(1);")
        let html = bundle?.bundledHTML() ?? ""
        XCTAssertTrue(html.contains("body { color: red; }"))
        XCTAssertTrue(html.contains("console.log(1);"))
        XCTAssertTrue(html.contains("data-aiity-bundle"))
    }

    func testSanitizeBlocksTraversal() {
        XCTAssertEqual(MiniAppBundleParser.sanitizePath("../etc/passwd"), "")
        XCTAssertEqual(MiniAppBundleParser.sanitizePath("app.js"), "app.js")
    }

    func testDraftExtractUsesBundle() {
        let text = """
        ```html
        <!doctype html><html><head><title>X</title><meta name="viewport" content="w"></head><body></body></html>
        ```
        ```css
        .a{}
        ```
        """
        let draft = MiniAppDraft.extract(from: text)
        XCTAssertEqual(draft?.name, "X")
        XCTAssertTrue(draft?.html.contains(".a{}") == true)
        XCTAssertNotEqual(draft?.filesJSON, "{}")
    }

    func testZipStoreMethodExtractsSkillMd() throws {
        // Minimal ZIP with one stored (method 0) entry SKILL.md
        let payload = Data("# Hello Skill\nDo the thing.\n".utf8)
        let name = Data("SKILL.md".utf8)
        var zip = Data()
        // local file header
        zip.append(contentsOf: [0x50, 0x4b, 0x03, 0x04]) // sig
        zip.append(contentsOf: [0x14, 0x00]) // version
        zip.append(contentsOf: [0x00, 0x00]) // flags
        zip.append(contentsOf: [0x00, 0x00]) // method store
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // time/date
        zip.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // crc
        let size = UInt32(payload.count)
        zip.append(contentsOf: withUnsafeBytes(of: size.littleEndian, Array.init))
        zip.append(contentsOf: withUnsafeBytes(of: size.littleEndian, Array.init))
        let nlen = UInt16(name.count)
        zip.append(contentsOf: withUnsafeBytes(of: nlen.littleEndian, Array.init))
        zip.append(contentsOf: [0x00, 0x00]) // extra
        zip.append(name)
        zip.append(payload)
        // end of central directory (minimal) — extractor only walks local headers
        let md = try ZipSkillExtractor.skillMarkdown(from: zip)
        XCTAssertTrue(md.contains("Hello Skill"))
    }
}
