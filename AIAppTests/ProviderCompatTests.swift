import XCTest
@testable import AIApp

final class ProviderCompatTests: XCTestCase {

    func testEndpointDoesNotDoubleV1() {
        let url = ProviderRequestSupport.endpoint(base: "https://api.openai.com/v1", path: "/chat/completions")
        XCTAssertEqual(url?.absoluteString, "https://api.openai.com/v1/chat/completions")

        let anthropic = ProviderRequestSupport.endpoint(base: "https://proxy.example/v1", path: "/v1/messages")
        XCTAssertEqual(anthropic?.absoluteString, "https://proxy.example/v1/messages")

        let bare = ProviderRequestSupport.endpoint(base: "https://api.anthropic.com", path: "/v1/messages")
        XCTAssertEqual(bare?.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testContentStringOrParts() {
        XCTAssertEqual(ProviderRequestSupport.text(fromContent: "hi"), "hi")
        let parts: [[String: Any]] = [
            ["type": "text", "text": "Hel"],
            ["type": "text", "text": "lo"],
        ]
        XCTAssertEqual(ProviderRequestSupport.text(fromContent: parts), "Hello")
    }

    func testToolUnsupportedDetection() {
        XCTAssertTrue(ProviderRequestSupport.isToolUnsupportedError(
            status: 400,
            body: #"{"error":{"message":"model does not support tools"}}"#
        ))
        XCTAssertTrue(ProviderRequestSupport.isToolUnsupportedError(
            status: 400,
            body: "registry.ollama.ai does not support tools"
        ))
        XCTAssertFalse(ProviderRequestSupport.isToolUnsupportedError(
            status: 401,
            body: "invalid api key"
        ))
    }

    func testFriendlyModelNotFound() {
        let msg = ProviderRequestSupport.friendlyError(
            status: 404,
            body: #"{"error":{"message":"The model `gpt-5.2` does not exist"}}"#
        )
        XCTAssertTrue(msg.lowercased().contains("modell"), msg)
        XCTAssertTrue(msg.contains("Modelle laden") || msg.contains("exist"), msg)
    }

    func testDefaultModelsAreNonEmptyForCloud() {
        for preset in ProviderPreset.catalog where preset.needsKey && preset.dialect != .mlx {
            // Bring-your-own-endpoint presets (custom-openai) and Together let
            // the user pick the model, so an empty default is expected there.
            if preset.editableBaseURL || preset.id == "together" { continue }
            XCTAssertFalse(preset.defaultModel.isEmpty, preset.id)
        }
    }

    func testTokenLimitUsesCompletionTokensForOSeries() {
        var body: [String: Any] = [:]
        OpenAICompatibleProvider.applyTokenLimit(&body, model: "o3-mini")
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 12_288)
        XCTAssertNil(body["max_tokens"])

        body = [:]
        OpenAICompatibleProvider.applyTokenLimit(&body, model: "gpt-4o")
        XCTAssertEqual(body["max_tokens"] as? Int, 12_288)
        XCTAssertNil(body["max_completion_tokens"])
    }

    func testFetchURLBlocksPrivateHosts() {
        for host in ["localhost", "127.0.0.1", "10.1.2.3", "192.168.0.5", "172.16.9.9",
                     "169.254.169.254", "100.93.237.25", "nas.local", "box.internal", "::1"] {
            XCTAssertTrue(FetchURLTool.isPrivateHost(host), "should block \(host)")
        }
        for host in ["example.com", "api.openai.com", "8.8.8.8", "172.32.0.1", "100.200.0.1", "duckduckgo.com"] {
            XCTAssertFalse(FetchURLTool.isPrivateHost(host), "should allow \(host)")
        }
    }

    func testGrokCLIHeadersOnlyForProxyOAuth() {
        var req = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/chat/completions")!)
        ProviderRequestSupport.applyOpenAICompatHeaders(to: &req, apiKey: "oauth:tok", baseURL: "https://cli-chat-proxy.grok.com/v1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-xai-token-auth"), "xai-grok-cli")
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.contains("grok-pager") == true)
        // A plain API key must NOT send the CLI identity.
        var req2 = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        ProviderRequestSupport.applyOpenAICompatHeaders(to: &req2, apiKey: "sk-plain", baseURL: "https://api.x.ai/v1")
        XCTAssertNil(req2.value(forHTTPHeaderField: "x-xai-token-auth"))
    }

    func testLocalToolsGatedByPreference() {
        let key = AppPreferences.allowLocalToolsKey
        let original = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        var settings = ProviderSettings()
        settings.presetId = "ollama"
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(LocalRuntimePolicy.shouldSendTools(settings), "local off by default")
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(LocalRuntimePolicy.shouldSendTools(settings), "local on when enabled")
        // Cloud always gets tools regardless of the toggle.
        settings.presetId = "anthropic"
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertTrue(LocalRuntimePolicy.shouldSendTools(settings))
    }

    func testSystemPromptLocalShorterThanCloud() {
        var settings = ProviderSettings()
        settings.presetId = "ollama"
        let local = ChatSession.buildSystemPrompt(settings: settings, editing: nil, userText: "hi")
        settings.presetId = "anthropic"
        let cloud = ChatSession.buildSystemPrompt(settings: settings, editing: nil, userText: "hi")
        XCTAssertTrue(local.count < cloud.count)
        XCTAssertTrue(local.count < ChatSession.systemPrompt.count)
    }

    @MainActor
    func testSystemPromptBudgetTruncatesHugeSkills() {
        // Simulate by installing a huge skill into a temp store file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-budget-\(UUID().uuidString).json")
        SkillStore.fileURLOverride = url
        defer {
            try? FileManager.default.removeItem(at: url)
            SkillStore.fileURLOverride = nil
        }
        let store = SkillStore()
        let blob = String(repeating: "Skill line about widgets. ", count: 400)
        _ = store.installPackage(markdown: """
        ---
        name: Huge
        summary: big
        ---
        \(blob)
        """, source: "test/huge")
        var settings = ProviderSettings()
        settings.presetId = "ollama"
        let prompt = ChatSession.buildSystemPrompt(settings: settings, editing: nil)
        XCTAssertTrue(prompt.contains("skills truncated") || prompt.count < blob.count + 2000)
    }
}
