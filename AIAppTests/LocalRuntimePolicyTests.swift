import XCTest
@testable import AIApp

final class LocalRuntimePolicyTests: XCTestCase {

    func testLocalDetection() {
        var s = ProviderSettings()
        s.presetId = "ollama"
        XCTAssertTrue(LocalRuntimePolicy.isLocal(s))
        XCTAssertFalse(LocalRuntimePolicy.shouldSendTools(s))

        s.presetId = "lmstudio"
        XCTAssertTrue(LocalRuntimePolicy.isLocal(s))

        s.presetId = "mlx"
        XCTAssertTrue(LocalRuntimePolicy.isLocal(s))

        s.presetId = "openai"
        XCTAssertFalse(LocalRuntimePolicy.isLocal(s))
        XCTAssertTrue(LocalRuntimePolicy.shouldSendTools(s))
    }

    func testSkillInjectionOnlyForAppRequests() {
        XCTAssertFalse(LocalRuntimePolicy.shouldInjectSkills(userText: "What's the capital of France?"))
        XCTAssertTrue(LocalRuntimePolicy.shouldInjectSkills(userText: "Bau mir eine Todo App"))
        XCTAssertTrue(LocalRuntimePolicy.shouldInjectSkills(userText: "build a timer widget"))
    }

    func testToolRegistryEmptyForOllama() async {
        var s = ProviderSettings()
        s.presetId = "ollama"
        let tools = await ToolRegistry.makeTools(settings: s, apiKey: "")
        XCTAssertTrue(tools.isEmpty)
    }

    func testToolRegistryHasSearchForOpenAI() async {
        var s = ProviderSettings()
        s.presetId = "openai"
        let tools = await ToolRegistry.makeTools(settings: s, apiKey: "sk-test")
        XCTAssertTrue(tools.map { $0.spec.name }.contains("web_search"))
    }
}
