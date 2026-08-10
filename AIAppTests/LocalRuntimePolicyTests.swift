import XCTest
@testable import AIApp

final class LocalRuntimePolicyTests: XCTestCase {

    /// Both switches this suite touches are global UserDefaults state — restore
    /// them so test order cannot decide the outcome.
    private var originalGlobalFlag = false
    private var originalPolicies: [String: String]?

    override func setUp() {
        super.setUp()
        originalGlobalFlag = UserDefaults.standard.bool(forKey: AppPreferences.allowLocalToolsKey)
        originalPolicies = UserDefaults.standard
            .dictionary(forKey: LocalRuntimePolicy.toolPolicyKey) as? [String: String]
        UserDefaults.standard.set(false, forKey: AppPreferences.allowLocalToolsKey)
        UserDefaults.standard.removeObject(forKey: LocalRuntimePolicy.toolPolicyKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(originalGlobalFlag, forKey: AppPreferences.allowLocalToolsKey)
        if let originalPolicies {
            UserDefaults.standard.set(originalPolicies, forKey: LocalRuntimePolicy.toolPolicyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalRuntimePolicy.toolPolicyKey)
        }
        super.tearDown()
    }

    private func settings(_ presetId: String) -> ProviderSettings {
        var s = ProviderSettings()
        s.presetId = presetId
        return s
    }

    // MARK: - The two predicates

    /// Endpoint locality: everything the user points at an address of their
    /// own, plus on-device.
    func testSelfHostedCoversEveryBringYourOwnAddressPreset() {
        for id in ["ollama", "lmstudio", "localai", "custom-openai", "custom-anthropic", "sub2api", "mlx"] {
            XCTAssertTrue(LocalRuntimePolicy.isSelfHosted(settings(id)), "\(id) is a self-hosted endpoint")
        }
        for id in ["openai", "anthropic", "openrouter", "gemini"] {
            XCTAssertFalse(LocalRuntimePolicy.isSelfHosted(settings(id)), "\(id) is a hosted service")
        }
    }

    /// Capability: only the genuine small-model runtimes.
    func testSmallModelProfileIsOnlyTheRealLocalRuntimes() {
        for id in ["ollama", "lmstudio", "localai", "mlx"] {
            XCTAssertTrue(LocalRuntimePolicy.usesSmallModelProfile(settings(id)), "\(id) runs small models")
        }
        for id in ["custom-openai", "sub2api", "openai", "anthropic", "openrouter"] {
            XCTAssertFalse(LocalRuntimePolicy.usesSmallModelProfile(settings(id)),
                           "\(id) must not be treated as a small local model")
        }
    }

    /// The whole point of splitting them: the two predicates disagree on
    /// exactly the two gateway/BYO-URL presets, and nowhere else.
    func testThePredicatesDisagreeExactlyOnTheGatewayPresets() {
        let disagreeing = ProviderPreset.catalog
            .map(\.id)
            .filter {
                LocalRuntimePolicy.isSelfHosted(settings($0))
                    != LocalRuntimePolicy.usesSmallModelProfile(settings($0))
            }
        XCTAssertEqual(Set(disagreeing), ["custom-openai", "custom-anthropic", "sub2api"])
    }

    // MARK: - Tool gating

    func testGatewayAndCustomEndpointsGetToolsByDefault() {
        for id in ["sub2api", "custom-openai"] {
            XCTAssertTrue(LocalRuntimePolicy.shouldSendTools(settings(id)),
                          "\(id) fronts real models — tools must be sent by default")
        }
    }

    func testSmallRuntimesGetNoToolsByDefault() {
        for id in ["ollama", "lmstudio", "localai", "mlx"] {
            XCTAssertFalse(LocalRuntimePolicy.shouldSendTools(settings(id)),
                           "\(id) keeps the small-model protection")
        }
    }

    func testCloudProvidersAlwaysGetToolsByDefault() {
        for id in ["openai", "anthropic", "openrouter"] {
            XCTAssertTrue(LocalRuntimePolicy.shouldSendTools(settings(id)))
        }
    }

    /// Force-ON for a capable LAN model, force-OFF for a tiny model behind a
    /// custom endpoint — the override has to work in both directions.
    func testPerProviderPolicyOverridesInBothDirections() {
        LocalRuntimePolicy.setToolPolicy(.always, forPresetId: "ollama")
        XCTAssertTrue(LocalRuntimePolicy.shouldSendTools(settings("ollama")), "opt in for a capable local model")

        LocalRuntimePolicy.setToolPolicy(.never, forPresetId: "custom-openai")
        XCTAssertFalse(LocalRuntimePolicy.shouldSendTools(settings("custom-openai")), "opt out for a tiny model")

        LocalRuntimePolicy.setToolPolicy(.never, forPresetId: "openai")
        XCTAssertFalse(LocalRuntimePolicy.shouldSendTools(settings("openai")), "even a cloud provider can be muted")

        // Back to auto = back to the defaults, and the entry is dropped.
        for id in ["ollama", "custom-openai", "openai"] {
            LocalRuntimePolicy.setToolPolicy(.auto, forPresetId: id)
            XCTAssertEqual(LocalRuntimePolicy.toolPolicy(forPresetId: id), .auto)
        }
        XCTAssertFalse(LocalRuntimePolicy.shouldSendTools(settings("ollama")))
        XCTAssertTrue(LocalRuntimePolicy.shouldSendTools(settings("custom-openai")))
        XCTAssertTrue(LocalRuntimePolicy.shouldSendTools(settings("openai")))
        XCTAssertNil(UserDefaults.standard.dictionary(forKey: LocalRuntimePolicy.toolPolicyKey),
                     "an all-auto state stores nothing")
    }

    /// One provider's choice must not leak into the next one.
    func testPolicyIsScopedToOneProvider() {
        LocalRuntimePolicy.setToolPolicy(.always, forPresetId: "ollama")
        XCTAssertFalse(LocalRuntimePolicy.shouldSendTools(settings("lmstudio")),
                       "lmstudio keeps its own default")
        XCTAssertEqual(LocalRuntimePolicy.toolPolicy(forPresetId: "lmstudio"), .auto)
    }

    /// The legacy global switch still flips every small runtime at once, and
    /// still cannot take tools away from anyone else.
    func testGlobalSwitchStillActsAsTheDefaultForSmallRuntimes() {
        UserDefaults.standard.set(true, forKey: AppPreferences.allowLocalToolsKey)
        for id in ["ollama", "lmstudio", "localai", "mlx"] {
            XCTAssertTrue(LocalRuntimePolicy.shouldSendTools(settings(id)))
        }
        XCTAssertTrue(LocalRuntimePolicy.shouldSendTools(settings("openai")))
        // A per-provider "never" still wins over the global "on".
        LocalRuntimePolicy.setToolPolicy(.never, forPresetId: "ollama")
        XCTAssertFalse(LocalRuntimePolicy.shouldSendTools(settings("ollama")))
    }

    // MARK: - What the split changes downstream

    func testSkillInjectionOnlyForAppRequests() {
        XCTAssertFalse(LocalRuntimePolicy.shouldInjectSkills(userText: "What's the capital of France?"))
        XCTAssertTrue(LocalRuntimePolicy.shouldInjectSkills(userText: "Bau mir eine Todo App"))
        XCTAssertTrue(LocalRuntimePolicy.shouldInjectSkills(userText: "build a timer widget"))
    }

    func testToolRegistryEmptyForOllama() async {
        let tools = await ToolRegistry.makeTools(settings: settings("ollama"), apiKey: "")
        XCTAssertTrue(tools.isEmpty)
    }

    func testToolRegistryHasSearchForOpenAI() async {
        let tools = await ToolRegistry.makeTools(settings: settings("openai"), apiKey: "sk-test")
        XCTAssertTrue(tools.map { $0.spec.name }.contains("web_search"))
    }

    /// The regression this whole change exists for: image generation and web
    /// search were silently missing on the gateway preset the app uses to test
    /// image generation in the first place.
    func testGatewayGetsTheWebToolsAndTheFullPrompt() async {
        var s = settings("sub2api")
        s.baseURL = "https://gateway.example/v1"
        let names = await ToolRegistry.makeTools(settings: s, apiKey: "sk-test").map { $0.spec.name }
        XCTAssertTrue(names.contains("web_search"), "sub2api must offer web_search")
        XCTAssertTrue(names.contains("fetch_url"), "sub2api must offer fetch_url")

        let gatewayPrompt = ChatSession.buildSystemPrompt(settings: s, editing: nil, userText: "hi")
        let ollamaPrompt = ChatSession.buildSystemPrompt(settings: settings("ollama"), editing: nil, userText: "hi")
        XCTAssertGreaterThan(gatewayPrompt.count, ollamaPrompt.count,
                             "a gateway must not get the reduced local prompt")
    }

    func testCustomOpenAIGetsTheWebTools() async {
        var s = settings("custom-openai")
        s.baseURL = "https://api.example.com/v1"
        let names = await ToolRegistry.makeTools(settings: s, apiKey: "sk-test").map { $0.spec.name }
        XCTAssertTrue(names.contains("web_search"))
    }
}
