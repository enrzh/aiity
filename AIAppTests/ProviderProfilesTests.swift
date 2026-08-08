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

    /// Empty model = "the user has not chosen yet" — switching providers must
    /// NOT paper over it with preset.defaultModel (the old behavior). Requests
    /// still work through the transient effectiveModel fallback.
    func testApplyKeepsAnUnchosenModelEmpty() {
        var settings = ProviderSettings()
        var profile = ProviderProfile()
        profile.model = ""
        ProviderProfiles.apply(profile, presetId: "anthropic", to: &settings)
        XCTAssertEqual(settings.presetId, "anthropic")
        XCTAssertTrue(settings.model.isEmpty,
                      "apply must not silently commit a default model")
        XCTAssertEqual(settings.effectiveModel,
                       ProviderPreset.preset(for: "anthropic").defaultModel,
                       "request-time fallback must stay intact")
    }

    /// A full switch round-trip (capture -> apply) preserves emptiness: the
    /// "no model chosen" state survives leaving and re-entering a provider.
    func testCaptureApplyRoundTripPreservesEmptyModel() {
        var settings = ProviderSettings()
        settings.presetId = "openai"
        settings.model = ""
        ProviderProfiles.capture(from: settings)

        var restored = ProviderSettings()
        ProviderProfiles.apply(
            ProviderProfiles.profile(for: "openai"),
            presetId: "openai",
            to: &restored
        )
        XCTAssertTrue(restored.model.isEmpty)
        XCTAssertTrue(ProviderProfiles.profile(for: "openai").model.isEmpty)
    }

    /// An actual prior choice, on the other hand, is restored verbatim.
    func testApplyRestoresAnActualPriorChoice() {
        var settings = ProviderSettings()
        var profile = ProviderProfile()
        profile.model = "claude-haiku-4-5"
        ProviderProfiles.apply(profile, presetId: "anthropic", to: &settings)
        XCTAssertEqual(settings.model, "claude-haiku-4-5")
    }

    func testApplyDoesNotTouchImageSlot() {
        var settings = ProviderSettings()
        settings.imagePresetId = "openai"
        settings.imageModel = "gpt-image-1"
        var profile = ProviderProfile()
        profile.model = "claude-sonnet-4-5"
        ProviderProfiles.apply(profile, presetId: "anthropic", to: &settings)
        XCTAssertEqual(settings.presetId, "anthropic")
        XCTAssertEqual(settings.imagePresetId, "openai")
        XCTAssertEqual(settings.imageModel, "gpt-image-1")
    }

    func testCaptureStoresLastMediaModelsOnSlotProviders() {
        var settings = ProviderSettings()
        settings.presetId = "anthropic"
        settings.model = "claude-sonnet-4-5"
        settings.imagePresetId = "openai"
        settings.imageModel = "dall-e-3"
        ProviderProfiles.capture(from: settings)

        let openai = ProviderProfiles.profile(for: "openai")
        XCTAssertEqual(openai.lastImageModel, "dall-e-3")
        // Chat profile for anthropic should not get media fields as chat model
        let anthropic = ProviderProfiles.profile(for: "anthropic")
        XCTAssertEqual(anthropic.model, "claude-sonnet-4-5")
    }

    func testLegacyProfileImageModelDecodesToLastImageModel() throws {
        let json = """
        {"baseURL":"","model":"gpt-4o","localModelId":"","imageModel":"gpt-image-1","videoModel":"sora-2"}
        """.data(using: .utf8)!
        // The dropped `videoModel` key must not break decoding of older blobs.
        let profile = try JSONDecoder().decode(ProviderProfile.self, from: json)
        XCTAssertEqual(profile.model, "gpt-4o")
        XCTAssertEqual(profile.lastImageModel, "gpt-image-1")
    }
}
