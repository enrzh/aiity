import XCTest
@testable import AIApp

final class ProviderProfilesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProviderProfiles.saveAll([:])
    }

    func testSwitchPreservesPerProviderModel() {
        var settings = ProviderSettings()
        settings.presetId = "openai"
        settings.model = "gpt-4o"
        settings.baseURL = ""
        ProviderProfiles.capture(from: settings)

        settings.presetId = "ollama"
        settings.model = "llama3.2"
        settings.baseURL = "http://192.168.1.10:11434/v1"
        ProviderProfiles.capture(from: settings)

        // Switch back to openai profile
        let openai = ProviderProfiles.profile(for: "openai")
        XCTAssertEqual(openai.model, "gpt-4o")

        let ollama = ProviderProfiles.profile(for: "ollama")
        XCTAssertEqual(ollama.model, "llama3.2")
        XCTAssertTrue(ollama.baseURL.contains("192.168"))
    }

    func testApplyFillsDefaultModelWhenEmpty() {
        var settings = ProviderSettings()
        var profile = ProviderProfile()
        profile.model = ""
        ProviderProfiles.apply(profile, presetId: "anthropic", to: &settings)
        XCTAssertEqual(settings.presetId, "anthropic")
        XCTAssertFalse(settings.model.isEmpty)
        XCTAssertEqual(settings.model, ProviderPreset.preset(for: "anthropic").defaultModel)
    }

    func testApplyDoesNotTouchImageVideoSlots() {
        var settings = ProviderSettings()
        settings.imagePresetId = "openai"
        settings.imageModel = "gpt-image-1"
        settings.videoPresetId = "openrouter"
        settings.videoModel = "sora-2"
        var profile = ProviderProfile()
        profile.model = "claude-sonnet-4-5"
        ProviderProfiles.apply(profile, presetId: "anthropic", to: &settings)
        XCTAssertEqual(settings.presetId, "anthropic")
        XCTAssertEqual(settings.imagePresetId, "openai")
        XCTAssertEqual(settings.imageModel, "gpt-image-1")
        XCTAssertEqual(settings.videoPresetId, "openrouter")
        XCTAssertEqual(settings.videoModel, "sora-2")
    }

    func testCaptureStoresLastMediaModelsOnSlotProviders() {
        var settings = ProviderSettings()
        settings.presetId = "anthropic"
        settings.model = "claude-sonnet-4-5"
        settings.imagePresetId = "openai"
        settings.imageModel = "dall-e-3"
        settings.videoPresetId = "openai"
        settings.videoModel = "sora-2"
        ProviderProfiles.capture(from: settings)

        let openai = ProviderProfiles.profile(for: "openai")
        XCTAssertEqual(openai.lastImageModel, "dall-e-3")
        XCTAssertEqual(openai.lastVideoModel, "sora-2")
        // Chat profile for anthropic should not get media fields as chat model
        let anthropic = ProviderProfiles.profile(for: "anthropic")
        XCTAssertEqual(anthropic.model, "claude-sonnet-4-5")
    }

    func testLegacyProfileImageModelDecodesToLastImageModel() throws {
        let json = """
        {"baseURL":"","model":"gpt-4o","localModelId":"","imageModel":"gpt-image-1","videoModel":"sora-2"}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(ProviderProfile.self, from: json)
        XCTAssertEqual(profile.model, "gpt-4o")
        XCTAssertEqual(profile.lastImageModel, "gpt-image-1")
        XCTAssertEqual(profile.lastVideoModel, "sora-2")
    }
}
