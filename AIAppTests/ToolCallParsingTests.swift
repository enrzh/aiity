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
