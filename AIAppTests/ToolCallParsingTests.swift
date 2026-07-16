import XCTest
@testable import AIApp

final class ToolCallParsingTests: XCTestCase {

    func testExtractSingleToolCall() {
        let text = """
        Ich suche das kurz.
        <tool_call>{"name": "web_search", "arguments": {"query": "wetter berlin"}}</tool_call>
        """
        let calls = MLXProvider.extractToolCalls(from: text)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "web_search")
        XCTAssertTrue(calls[0].argumentsJSON.contains("wetter berlin"))
    }

    func testExtractMultipleAndIgnoreBrokenJSON() {
        let text = """
        <tool_call>{"name": "web_search", "arguments": {"query": "a"}}</tool_call>
        <tool_call>not json</tool_call>
        <tool_call>{"name": "fetch_url", "arguments": {"url": "https://x.de"}}</tool_call>
        """
        let calls = MLXProvider.extractToolCalls(from: text)
        XCTAssertEqual(calls.map(\.name), ["web_search", "fetch_url"])
    }

    func testEmitterHoldsBackToolCallSpan() {
        var emitter = ToolCallStreamEmitter()
        var visible = ""
        var accumulated = ""
        for piece in ["Hallo ", "Welt! ", "<tool_", "call>{\"name\":\"web_search\",\"arguments\":{}}", "</tool_call>"] {
            accumulated += piece
            if let safe = emitter.consume(accumulated: accumulated) { visible += safe }
        }
        if let tail = emitter.finish(accumulated: accumulated) { visible += tail }
        XCTAssertEqual(visible, "Hallo Welt! ")
    }

    func testEmitterEmitsEverythingWithoutToolCall() {
        var emitter = ToolCallStreamEmitter()
        var visible = ""
        var accumulated = ""
        for piece in ["Nur ", "normaler ", "Text ohne Tags."] {
            accumulated += piece
            if let safe = emitter.consume(accumulated: accumulated) { visible += safe }
        }
        if let tail = emitter.finish(accumulated: accumulated) { visible += tail }
        XCTAssertEqual(visible, "Nur normaler Text ohne Tags.")
    }

    func testStrippingHTMLFence() {
        let text = "Hier deine App:\n```html\n<!doctype html><html></html>\n```\nViel Spaß!"
        XCTAssertEqual(ChatView.strippingHTMLFence(from: text), "Hier deine App:\n\nViel Spaß!")
        let streaming = "Hier deine App:\n```html\n<!doctype html><body>"
        XCTAssertEqual(ChatView.strippingHTMLFence(from: streaming), "Hier deine App:")
    }

    func testMiniAppDraftExtraction() {
        let text = """
        Fertig!
        ```html
        <!doctype html>
        <!-- emoji: 🧮 -->
        <html><head><title>Rechner</title></head><body></body></html>
        ```
        """
        let draft = MiniAppDraft.extract(from: text)
        XCTAssertEqual(draft?.name, "Rechner")
        XCTAssertEqual(draft?.emoji, "🧮")
    }
}
