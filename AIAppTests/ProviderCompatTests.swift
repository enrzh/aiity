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

    func testWebAppBuilderDetectsOpenRequests() {
        XCTAssertEqual(WebAppBuilder.detectOpenRequest("Öffne music.youtube.com als Browser-Mini-App"), "music.youtube.com")
        XCTAssertEqual(WebAppBuilder.detectOpenRequest("open example.com"), "example.com")
        XCTAssertEqual(WebAppBuilder.detectOpenRequest("youtube.com"), "youtube.com")
        // A long, non-.com TLD still parses as a bare host.
        XCTAssertEqual(WebAppBuilder.detectOpenRequest("open example.museum"), "example.museum")
        XCTAssertEqual(WebAppBuilder.detectOpenRequest("https://foo.bar/x"), "https://foo.bar/x")
        // Not open-requests:
        XCTAssertNil(WebAppBuilder.detectOpenRequest("Bau mir einen Trinkgeld-Rechner"))
        XCTAssertNil(WebAppBuilder.detectOpenRequest("was ist youtube.com für ein service"))
        XCTAssertNil(WebAppBuilder.detectOpenRequest("erkläre mir z.b. das"))
    }

    func testWebAppBuilderHTMLIsBrowserCapability() {
        let html = WebAppBuilder.html(urlString: "youtube.com")
        XCTAssertTrue(html.contains("capability: browser"))
        XCTAssertTrue(html.contains("https://youtube.com"))
        XCTAssertEqual(MiniAppCapability.from(html: html), .browser)
    }

    func testFetchURLBlocksPrivateHosts() {
        for host in ["localhost", "127.0.0.1", "10.1.2.3", "192.168.0.5", "172.16.9.9",
                     "169.254.169.254", "100.64.0.1", "nas.local", "box.internal", "::1"] {
            XCTAssertTrue(FetchURLTool.isPrivateHost(host), "should block \(host)")
        }
        for host in ["example.com", "api.openai.com", "8.8.8.8", "172.32.0.1", "100.200.0.1", "duckduckgo.com"] {
            XCTAssertFalse(FetchURLTool.isPrivateHost(host), "should allow \(host)")
        }
    }

    /// aiity identifies as itself. No request may claim to be somebody else's
    /// CLI — that was the reason the Grok/ChatGPT subscription paths were cut,
    /// and the headers that did it must not creep back in.
    func testOpenAICompatRequestsDoNotImpersonateAnotherClient() {
        for (base, key) in [
            ("https://api.x.ai/v1", "oauth:tok"),
            ("https://api.x.ai/v1", "sk-plain"),
            ("https://cli-chat-proxy.grok.com/v1", "oauth:tok"),
            ("https://api.openai.com/v1", "sk-plain"),
        ] {
            var request = URLRequest(url: URL(string: base + "/chat/completions")!)
            ProviderRequestSupport.applyOpenAICompatHeaders(to: &request, apiKey: key, baseURL: base)
            XCTAssertNil(request.value(forHTTPHeaderField: "x-xai-token-auth"), base)
            XCTAssertNil(request.value(forHTTPHeaderField: "x-grok-client-version"), base)
            let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            XCTAssertFalse(agent.contains("grok-pager"), base)
            XCTAssertFalse(agent.contains("cli"), base)
        }
    }

    /// OpenRouter's ranking headers are the one exception — they name aiity as
    /// aiity, which is attribution rather than impersonation.
    func testOpenRouterAttributionHeadersAreSent() {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        ProviderRequestSupport.applyOpenAICompatHeaders(
            to: &request, apiKey: "sk-or", baseURL: "https://openrouter.ai/api/v1"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "aiity")
    }

    /// Every preset must build a sane chat endpoint from its own base URL —
    /// no doubled `/v1`, no missing path.
    func testEveryPresetBuildsAValidChatEndpoint() {
        for preset in ProviderPreset.catalog where preset.dialect == .openai {
            guard !preset.defaultBaseURL.isEmpty else { continue }  // BYO-URL presets
            let url = ProviderRequestSupport.endpoint(
                base: preset.defaultBaseURL, path: "/chat/completions"
            )
            let string = url?.absoluteString ?? ""
            XCTAssertTrue(string.hasSuffix("/chat/completions"), "\(preset.id): \(string)")
            XCTAssertFalse(string.contains("/v1/v1"), "\(preset.id) doubled /v1: \(string)")
        }
    }

    /// A cloud preset with no default model leaves the user staring at an empty
    /// picker before the catalog loads.
    func testKeyedCloudPresetsShipADefaultModel() {
        let byoURL: Set<String> = ["custom-openai", "custom-anthropic", "sub2api", "localai", "ollama", "lmstudio", "mlx"]
        for preset in ProviderPreset.catalog where preset.needsKey && !byoURL.contains(preset.id) {
            XCTAssertFalse(preset.defaultModel.isEmpty, "\(preset.id) has no default model")
        }
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

    func testFriendly429DistinguishesQuotaFromRateLimit() {
        let quota = ProviderRequestSupport.friendlyError(
            status: 429,
            body: #"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota"}}"#
        )
        XCTAssertTrue(quota.lowercased().contains("guthaben") || quota.lowercased().contains("kontingent"), quota)
        XCTAssertFalse(quota.contains("kurz warten"), quota)

        let rate = ProviderRequestSupport.friendlyError(
            status: 429,
            body: #"{"error":{"message":"Rate limit reached for requests"}}"#
        )
        XCTAssertTrue(rate.contains("kurz warten"), rate)
    }

    func testAnthropicCoalescesAdjacentUserTurns() {
        // tool_result user turn + "stop using tools" user turn must merge into one
        // (Anthropic requires alternating roles; two user turns = HTTP 400).
        let merged = AnthropicProvider.coalesceAdjacentRoles([
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]],
            ["role": "user", "content": "Stop using tools."],
            ["role": "assistant", "content": "done"],
        ])
        XCTAssertEqual(merged.count, 2, "adjacent user turns should merge")
        XCTAssertEqual(merged[0]["role"] as? String, "user")
        let blocks = merged[0]["content"] as? [[String: Any]]
        XCTAssertEqual(blocks?.count, 2)
        XCTAssertEqual(blocks?.first?["type"] as? String, "tool_result")
        XCTAssertEqual(blocks?.last?["type"] as? String, "text")
    }

    func testFetchURLBlocksEncodedAndPrivateHosts() {
        for host in ["2130706433", "0x7f000001", "192.168.1.1", "169.254.169.254",
                     "100.64.0.1", "localhost", "10.0.0.1", "::1",
                     // Alternative encodings that a plain dotted-quad check misses:
                     "0177.0.0.1",              // octal
                     "127.1",                   // short form
                     "::ffff:127.0.0.1",        // IPv4-mapped IPv6
                     "[::ffff:192.168.0.1]",    // bracketed IPv4-mapped
                     "0:0:0:0:0:0:0:1",         // expanded IPv6 loopback
                     "::",                      // unspecified
                     "fe80::1",                 // link-local
                     "fd00::1",                 // unique-local
                     "localhost.",              // trailing root dot
                     "user@127.0.0.1",          // userinfo prefix
                     "0x7f.0x0.0x0.0x1"] {      // hex per-octet
            XCTAssertTrue(FetchURLTool.isBlockedHost(host), "should block \(host)")
        }
        for host in ["8.8.8.8", "example.com", "api.openai.com", "1.1.1.1", "172.32.0.1"] {
            XCTAssertFalse(FetchURLTool.isBlockedHost(host), "should allow \(host)")
        }
    }

    func testMediaModelResolutionKeepsExplicitChoice() {
        // A configured, explicit choice is never silently swapped for a
        // catalog entry, even when the cache doesn't list it.
        XCTAssertEqual(
            MediaRoute.resolveModel("my-custom-image", presetId: "sub2api", modality: .image),
            "my-custom-image"
        )
        // The image slot must never fall back to a video model.
        let resolved = MediaRoute.resolveModel(
            ModelModality.image.defaultModel, presetId: "sub2api", modality: .image
        )
        let lower = resolved.lowercased()
        XCTAssertFalse(lower.contains("sora") || lower.contains("veo"),
                       "image slot must not resolve to a video model, got \(resolved)")
    }

    @MainActor
    func testSkillReplaceVsForkPredicate() {
        let existing = AgentSkill(name: "PDF", summary: "s", instructions: "orig",
                                  enabled: true, packageVersion: nil, source: "github:a/pdf")
        // Same origin = upgrade (replaces in place).
        XCTAssertTrue(SkillStore.replacesExisting(existing, instructions: "v2", source: "github:a/pdf"))
        // Identical content = no-op replace.
        XCTAssertTrue(SkillStore.replacesExisting(existing, instructions: "orig", source: "github:b/pdf"))
        // Different origin + different content = fork (a genuinely new skill).
        XCTAssertFalse(SkillStore.replacesExisting(existing, instructions: "other", source: "github:b/pdf"))
    }

    func testMiniAppConsentNoSilentEscalation() {
        XCTAssertLessThan(MiniAppCapability.offline.rank, MiniAppCapability.network.rank)
        XCTAssertLessThan(MiniAppCapability.network.rank, MiniAppCapability.browser.rank)
        let id = "test-escalation-" + UUID().uuidString
        MiniAppConsent.allow(appId: id, capability: .network)
        XCTAssertTrue(MiniAppConsent.isAllowed(appId: id, declared: .network))
        XCTAssertTrue(MiniAppConsent.isAllowed(appId: id, declared: .offline))
        XCTAssertFalse(MiniAppConsent.isAllowed(appId: id, declared: .browser),
                       "a network grant must NOT silently satisfy a browser app")
    }

    func testNormalizeBaseURLMatrix() {
        let openai: [(String, String)] = [
            // schemeless LAN → http (the common sub2api-on-a-box case)
            ("192.168.1.10:8090", "http://192.168.1.10:8090/v1"),
            ("10.0.0.5", "http://10.0.0.5/v1"),
            ("172.16.4.2", "http://172.16.4.2/v1"),
            ("100.101.102.103", "http://100.101.102.103/v1"),   // Tailscale CGNAT
            ("169.254.10.10", "http://169.254.10.10/v1"),
            ("localhost:1234", "http://localhost:1234/v1"),
            ("host.local", "http://host.local/v1"),
            ("gateway", "http://gateway/v1"),                    // bare single-label
            ("[::1]:8090", "http://[::1]:8090/v1"),
            // boundary traps: just outside the private ranges → public → https
            ("172.32.0.1", "https://172.32.0.1/v1"),
            ("100.200.0.1", "https://100.200.0.1/v1"),
            ("8.8.8.8", "https://8.8.8.8/v1"),
            // public hostnames → https
            ("my.gateway.com", "https://my.gateway.com/v1"),
            // explicit scheme always honored
            ("http://my.gateway.com", "http://my.gateway.com/v1"),
            ("https://my.gateway.com", "https://my.gateway.com/v1"),
            // idempotent /v1, trailing slash, pasted endpoints / admin
            ("https://api.openai.com/v1", "https://api.openai.com/v1"),
            ("https://ki.domain.de/", "https://ki.domain.de/v1"),
            ("http://host:8090/v1/chat/completions", "http://host:8090/v1"),
            ("https://ki.domain.de/v1/models", "https://ki.domain.de/v1"),
            ("https://gateway.example.com/admin", "https://gateway.example.com/v1"),
            ("192.168.0.10/chat/completions", "http://192.168.0.10/v1"),
            ("10.1.2.3:11434/v1", "http://10.1.2.3:11434/v1"),
        ]
        for (input, expected) in openai {
            XCTAssertEqual(
                ProviderSettings.normalizeBaseURL(input, dialect: .openai), expected,
                "openai normalize: \(input)"
            )
        }
        // Anthropic dialect must NOT get a /v1 root appended (callers add /v1/messages).
        XCTAssertEqual(
            ProviderSettings.normalizeBaseURL("https://api.anthropic.com", dialect: .anthropic),
            "https://api.anthropic.com"
        )
        XCTAssertEqual(
            ProviderSettings.normalizeBaseURL("my.claude-proxy.com", dialect: .anthropic),
            "https://my.claude-proxy.com"
        )
    }

    func testAnthropicMaxTokensClampsLegacyClaude3() {
        // Legacy Claude 3 caps at 4096; requesting more 400s a valid key.
        XCTAssertEqual(AnthropicProvider.maxTokens(for: "claude-3-opus-20240229", isOAuth: false), 4_096)
        XCTAssertEqual(AnthropicProvider.maxTokens(for: "claude-3-haiku-20240307", isOAuth: false), 4_096)
        // 3.5 / 3.7 and 4.x keep the higher budget.
        XCTAssertEqual(AnthropicProvider.maxTokens(for: "claude-3-5-sonnet-latest", isOAuth: false), 8_192)
        XCTAssertEqual(AnthropicProvider.maxTokens(for: "claude-sonnet-4-5", isOAuth: false), 8_192)
        XCTAssertEqual(AnthropicProvider.maxTokens(for: "claude-sonnet-4-5", isOAuth: true), 6_144)
    }
}
