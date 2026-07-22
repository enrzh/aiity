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

    func testParseAuthorizationInputBareCode() {
        let (code, state) = OAuthService.parseAuthorizationInput("  abc123  ")
        XCTAssertEqual(code, "abc123")
        XCTAssertNil(state)
    }

    func testParseAuthorizationInputClaudeCodeHashState() {
        let (code, state) = OAuthService.parseAuthorizationInput("theCode#theState")
        XCTAssertEqual(code, "theCode")
        XCTAssertEqual(state, "theState")
    }

    func testParseAuthorizationInputLocalhostRedirectURL() {
        let (code, state) = OAuthService.parseAuthorizationInput("http://localhost:1455/auth/callback?code=xyz789&state=st42")
        XCTAssertEqual(code, "xyz789")
        XCTAssertEqual(state, "st42")
    }

    func testNormalizeBaseURLAddsSchemeAndVersion() {
        XCTAssertEqual(ProviderSettings.normalizeBaseURL("ki.meine-domain.de", dialect: .openai),
                       "https://ki.meine-domain.de/v1")
    }

    func testNormalizeBaseURLKeepsExistingPathAndTrimsSlash() {
        XCTAssertEqual(ProviderSettings.normalizeBaseURL("https://host/api/v3/", dialect: .openai),
                       "https://host/api/v3")
        XCTAssertEqual(ProviderSettings.normalizeBaseURL("http://localhost:11434/v1", dialect: .openai),
                       "http://localhost:11434/v1")
    }

    func testNormalizeBaseURLAnthropicKeepsBareHost() {
        // Anthropic callers append their own /v1/messages path.
        XCTAssertEqual(ProviderSettings.normalizeBaseURL("meine-domain.de", dialect: .anthropic),
                       "https://meine-domain.de")
    }

    func testSub2apiBareDomainBecomesUsableEndpoint() {
        var settings = ProviderSettings()
        settings.presetId = "sub2api"
        settings.baseURL = "ki.dong-fang.de"
        XCTAssertEqual(settings.effectiveBaseURL, "https://ki.dong-fang.de/v1")
        XCTAssertEqual(settings.baseURL(forKey: "sk-abc"), "https://ki.dong-fang.de/v1")
    }

    func testCodexBuildBodyShapesResponsesRequest() {
        let messages = [
            ChatMessage(role: .system, text: "be helpful"),
            ChatMessage(role: .user, text: "hi"),
            ChatMessage(role: .assistant, text: "", toolCalls: [ToolCallData(id: "c1", name: "web_search", argumentsJSON: "{\"q\":\"x\"}")]),
            ChatMessage(role: .tool, text: "result", toolCallId: "c1", toolName: "web_search"),
        ]
        let body = OpenAICodexProvider.buildBody(messages: messages, tools: [], model: "gpt-5.2")
        XCTAssertEqual(body["model"] as? String, "gpt-5.2")
        XCTAssertEqual(body["instructions"] as? String, "be helpful")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        let input = body["input"] as! [[String: Any]]
        // user message, function_call, function_call_output — no system role.
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertEqual(input[1]["type"] as? String, "function_call")
        XCTAssertEqual(input[1]["call_id"] as? String, "c1")
        XCTAssertEqual(input[2]["type"] as? String, "function_call_output")
        XCTAssertFalse(input.contains { ($0["role"] as? String) == "system" })
    }

    func testCodexParseEventTextAndToolCall() {
        let textEvents = OpenAICodexProvider.parseEvent(#"{"type":"response.output_text.delta","delta":"Hel"}"#)
        guard case .textDelta(let t) = textEvents.first else { return XCTFail("expected text delta") }
        XCTAssertEqual(t, "Hel")

        let toolEvents = OpenAICodexProvider.parseEvent(#"{"type":"response.output_item.done","item":{"type":"function_call","name":"web_search","arguments":"{\"q\":\"a\"}","call_id":"c9"}}"#)
        guard case .toolCall(let call) = toolEvents.first else { return XCTFail("expected tool call") }
        XCTAssertEqual(call.name, "web_search")
        XCTAssertEqual(call.id, "c9")

        // Unrelated lifecycle events yield nothing.
        XCTAssertTrue(OpenAICodexProvider.parseEvent(#"{"type":"response.created"}"#).isEmpty)
    }

    func testParseDuckDuckGoLiteResults() {
        let html = """
        <table>
        <tr><td valign="top">1.&nbsp;</td><td><a rel="nofollow" href="https://www.swift.org/" class='result-link'>Swift.org &amp; docs</a></td></tr>
        <tr><td>&nbsp;</td><td class='result-snippet'>The Swift programming language.</td></tr>
        <tr><td valign="top">2.&nbsp;</td><td><a rel="nofollow" href="https://developer.apple.com/swift/" class="result-link">Apple Developer</a></td></tr>
        </table>
        """
        let out = WebSearchTool.parseLiteResults(html)
        XCTAssertTrue(out.contains("https://www.swift.org/"), "extracts first (single-quoted class) URL")
        XCTAssertTrue(out.contains("Swift.org & docs"), "decodes HTML entities in the title")
        XCTAssertTrue(out.contains("https://developer.apple.com/swift/"), "extracts second (double-quoted class) URL")
        XCTAssertTrue(out.hasPrefix("1."), "numbers the results")
    }

    func testParseDuckDuckGoLiteDecodesRedirectWrapper() {
        let html = #"<a href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&amp;rut=abc" class='result-link'>Example</a>"#
        let out = WebSearchTool.parseLiteResults(html)
        XCTAssertTrue(out.contains("https://example.com/page"), "decodes a uddg redirect wrapper to the real URL")
        XCTAssertFalse(out.contains("duckduckgo.com/l/"), "does not surface the redirect URL")
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
