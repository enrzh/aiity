import XCTest
@testable import AIApp

final class ConnectionProbeTests: XCTestCase {

    /// Presets the stub-backed tests probe. Their catalog cache is cleared
    /// around every test: `fetchModels` saves successful lists, and a stale
    /// cache would let a later error-path test "succeed" from cached models.
    private static let stubPresetIds = ["ollama", "custom-openai", "custom-anthropic"]

    override func setUp() {
        super.setUp()
        Self.clearCatalogCache()
    }

    override func tearDown() {
        Self.clearCatalogCache()
        super.tearDown()
    }

    private static func clearCatalogCache() {
        for id in stubPresetIds {
            UserDefaults.standard.removeObject(forKey: ModelCatalogCache.cacheKey(id))
        }
    }

    func testParseModelsOpenAIShapeSuccess() {
        let json = """
        {"data":[{"id":"llama3.2"},{"id":"qwen2.5"}]}
        """.data(using: .utf8)!
        let result = ConnectionProbe.parseModelsList(data: json, statusCode: 200)
        switch result {
        case .success(let ids):
            XCTAssertEqual(ids, ["llama3.2", "qwen2.5"])
        case .failure(let fail):
            XCTFail("expected success, got \(fail.message)")
        }
    }

    func testParseModelsOllamaTagsShape() {
        let json = """
        {"models":[{"name":"mistral:latest"},{"name":"phi3"}]}
        """.data(using: .utf8)!
        let result = ConnectionProbe.parseModelsList(data: json, statusCode: 200)
        switch result {
        case .success(let ids):
            XCTAssertEqual(ids, ["mistral:latest", "phi3"])
        case .failure(let fail):
            XCTFail(fail.message)
        }
    }

    func testParseModelsHTTPErrorHasReason() {
        let result = ConnectionProbe.parseModelsList(data: Data("nope".utf8), statusCode: 502)
        switch result {
        case .success:
            XCTFail("should fail")
        case .failure(let fail):
            XCTAssertTrue(fail.message.contains("502"), fail.message)
            XCTAssertFalse(fail.message.isEmpty)
        }
    }

    func testParseCompletionSuccess() {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":"ok"}}]}
        """.data(using: .utf8)!
        let result = ConnectionProbe.parseCompletionProbe(data: json, statusCode: 200)
        switch result {
        case .success(let text):
            XCTAssertEqual(text, "ok")
        case .failure(let fail):
            XCTFail(fail.message)
        }
    }

    func testParseCompletionFailureReason() {
        let result = ConnectionProbe.parseCompletionProbe(data: Data("err".utf8), statusCode: 401)
        if case .failure(let fail) = result {
            XCTAssertTrue(fail.message.contains("401"), fail.message)
        } else {
            XCTFail("expected failure")
        }
    }

    func testOllamaTagsURLFromV1Base() {
        let url = ConnectionProbe.ollamaTagsURL(from: "http://192.168.1.5:11434/v1")
        XCTAssertEqual(url?.absoluteString, "http://192.168.1.5:11434/api/tags")
    }

    func testLocalStylePresets() {
        XCTAssertTrue(ConnectionProbe.isLocalStyle("ollama"))
        XCTAssertTrue(ConnectionProbe.isLocalStyle("lmstudio"))
        XCTAssertFalse(ConnectionProbe.isLocalStyle("anthropic"))
    }

    func testCapabilitiesSteerLocalToTemplateMode() {
        var settings = ProviderSettings()
        settings.presetId = "ollama"
        let caps = ConnectionProbe.capabilities(for: settings)
        XCTAssertTrue(caps.tools)
        XCTAssertFalse(caps.miniAppPro)

        settings.presetId = "anthropic"
        let pro = ConnectionProbe.capabilities(for: settings)
        XCTAssertTrue(pro.miniAppPro)
    }

    func testProbeFailsClearlyOnUnreachableHost() async {
        var settings = ProviderSettings()
        settings.presetId = "ollama"
        settings.baseURL = "http://127.0.0.1:1"
        settings.model = "x"
        let result = await ConnectionProbe.test(settings: settings, apiKey: "")
        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Full probe against the in-process stub (all three wire shapes)

    /// OpenAI wire dialect end to end: GET /v1/models + non-stream test chat.
    func testFullProbeOpenAIDialectHappyPath() async throws {
        let server = try ProbeStubServer(mode: .openai)
        defer { server.stop() }
        var settings = ProviderSettings()
        settings.presetId = "custom-openai"
        settings.baseURL = server.baseURL
        let result = await ConnectionProbe.test(settings: settings, apiKey: "test-key")
        XCTAssertTrue(result.ok, result.reason)
        XCTAssertEqual(Set(result.models), ["stub-large", "stub-mini"])
        XCTAssertTrue(result.reason.contains("Verbunden"), result.reason)
        XCTAssertTrue(result.chatOnly, "custom-openai is local-style → template mode")
    }

    /// Anthropic wire dialect end to end: /v1/models list + /v1/messages chat.
    func testFullProbeAnthropicDialectHappyPath() async throws {
        let server = try ProbeStubServer(mode: .anthropic)
        defer { server.stop() }
        var settings = ProviderSettings()
        settings.presetId = "custom-anthropic"
        settings.baseURL = server.baseURL
        let result = await ConnectionProbe.test(settings: settings, apiKey: "")
        XCTAssertTrue(result.ok, result.reason)
        XCTAssertEqual(result.models, ["claude-stub-1"])
        XCTAssertTrue(result.reason.contains("Verbunden"), result.reason)
        XCTAssertFalse(result.chatOnly, "custom-anthropic is not local-style")
    }

    /// Native-Ollama runtime: /v1/models 404s, /api/tags carries the models,
    /// chat still answers on the OpenAI-compat endpoint.
    func testFullProbeOllamaNativeTagsFallback() async throws {
        let server = try ProbeStubServer(mode: .ollamaNative)
        defer { server.stop() }
        var settings = ProviderSettings()
        settings.presetId = "ollama"
        settings.baseURL = server.baseURL
        let result = await ConnectionProbe.test(settings: settings, apiKey: "")
        XCTAssertTrue(result.ok, result.reason)
        XCTAssertEqual(result.models, ["qwen2.5:0.5b"])
        XCTAssertTrue(result.chatOnly)
    }

    /// A 401 must surface as the user-facing models-list failure. The message
    /// is localized at runtime, so the status code is the locale-stable part.
    func testProbe401SurfacesUserFacingReason() async throws {
        let server = try ProbeStubServer(mode: .unauthorized)
        defer { server.stop() }
        var settings = ProviderSettings()
        settings.presetId = "custom-openai"
        settings.baseURL = server.baseURL
        let result = await ConnectionProbe.test(settings: settings, apiKey: "bad-key")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.reason.contains("HTTP 401"), result.reason)
    }

    /// Same for a 404 (wrong path / server without the API).
    func testProbe404SurfacesUserFacingReason() async throws {
        let server = try ProbeStubServer(mode: .notFound)
        defer { server.stop() }
        var settings = ProviderSettings()
        settings.presetId = "custom-openai"
        settings.baseURL = server.baseURL
        let result = await ConnectionProbe.test(settings: settings, apiKey: "k")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.reason.contains("HTTP 404"), result.reason)
    }

    /// Timeout maps to the friendly guidance (German source, localized at
    /// runtime) — never the raw NSURLError text.
    func testTimeoutMapsToFriendlyMessage() {
        let message = NetworkErrorFriendly.message(for: URLError(.timedOut))
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotEqual(message, URLError(.timedOut).localizedDescription)
        XCTAssertTrue(message.contains("Zeitüberschreitung") || message.contains("Timed out"),
                      message)
    }

    // MARK: - Test-chat request construction / auth headers (both dialects)

    func testCompletionRequestOpenAIUsesBearerAuth() throws {
        let request = try XCTUnwrap(ConnectionProbe.completionRequest(
            base: "https://api.groq.com/openai/v1", dialect: .openai,
            model: "m", apiKey: "sk-test"
        ))
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["stream"] as? Bool, false, "probe chat must be non-stream")
        XCTAssertEqual(object["model"] as? String, "m")
    }

    func testCompletionRequestAnthropicUsesApiKeyHeader() throws {
        let request = try XCTUnwrap(ConnectionProbe.completionRequest(
            base: "https://api.anthropic.com", dialect: .anthropic,
            model: "claude-x", apiKey: "sk-ant"
        ))
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    /// A subscription OAuth credential ("oauth:<token>") switches Anthropic to
    /// Bearer + the oauth beta header instead of x-api-key.
    func testCompletionRequestAnthropicOAuthUsesBearerAndBetaHeader() throws {
        let request = try XCTUnwrap(ConnectionProbe.completionRequest(
            base: "https://api.anthropic.com", dialect: .anthropic,
            model: "claude-x", apiKey: AuthStore.oauthMarker + "tok123"
        ))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testCompletionRequestMLXBuildsNothing() {
        XCTAssertNil(ConnectionProbe.completionRequest(
            base: "", dialect: .mlx, model: "m", apiKey: ""
        ))
    }
}
