import XCTest
@testable import AIApp

final class ConnectionProbeTests: XCTestCase {

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
}
