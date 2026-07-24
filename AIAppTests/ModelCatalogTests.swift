import XCTest
@testable import AIApp

final class ModelCatalogTests: XCTestCase {

    func testAutoPickKeepsCurrentIfPresent() {
        var settings = ProviderSettings()
        settings.presetId = "openrouter"
        settings.model = "openai/gpt-4o"
        let models = [
            CatalogModel(id: "openai/gpt-4o-mini"),
            CatalogModel(id: "openai/gpt-4o"),
            CatalogModel(id: "anthropic/claude-sonnet-4"),
        ]
        XCTAssertEqual(ModelCatalogService.autoPickModel(from: models, settings: settings), "openai/gpt-4o")
    }

    func testAutoPickPrefersDefaultThenRanked() {
        var settings = ProviderSettings()
        settings.presetId = "openrouter"
        settings.model = ""
        // default is openai/gpt-4o-mini
        let models = [
            CatalogModel(id: "anthropic/claude-sonnet-4", supportsTools: true),
            CatalogModel(id: "openai/gpt-4o-mini", supportsTools: true),
            CatalogModel(id: "some/embed", supportsTools: false),
        ]
        XCTAssertEqual(ModelCatalogService.autoPickModel(from: models, settings: settings), "openai/gpt-4o-mini")
    }

    func testRankDeprioritizesEmbeddings() {
        let models = [
            CatalogModel(id: "text-embedding-3-small", supportsTools: false),
            CatalogModel(id: "gpt-4o-mini", supportsTools: true),
        ]
        let ranked = ModelCatalogService.rank(models, preferTools: true, presetId: "openai")
        XCTAssertEqual(ranked.first?.id, "gpt-4o-mini")
    }

    func testInferToolsFalseForEmbedAndWhisper() {
        XCTAssertFalse(ModelCatalogService.inferTools(id: "text-embedding-3-large", presetId: "openai"))
        XCTAssertFalse(ModelCatalogService.inferTools(id: "whisper-1", presetId: "openai"))
        XCTAssertTrue(ModelCatalogService.inferTools(id: "gpt-4o", presetId: "openai"))
    }

    func testMediaCapabilityHidesForLocalAndOAuthOpenAI() {
        var settings = ProviderSettings()
        settings.presetId = "ollama"
        XCTAssertFalse(MediaCapability.supportsImageOrVideo(settings: settings, apiKey: "x"))
        XCTAssertFalse(MediaCapability.supportsImageGeneration(presetId: "ollama"))

        settings.presetId = "openai"
        XCTAssertFalse(MediaCapability.supportsImageOrVideo(
            settings: settings,
            apiKey: AuthStore.oauthMarker + "token"
        ))
        XCTAssertTrue(MediaCapability.supportsImageOrVideo(settings: settings, apiKey: "sk-test"))
        XCTAssertTrue(MediaCapability.supportsImageGeneration(presetId: "openai"))
        XCTAssertTrue(MediaCapability.supportsVideoGeneration(presetId: "openai"))

        settings.presetId = "anthropic"
        XCTAssertFalse(MediaCapability.supportsImageOrVideo(settings: settings, apiKey: "sk-ant"))
        XCTAssertFalse(MediaCapability.supportsImageGeneration(presetId: "anthropic"))
    }

    func testCodexOAuthModelsAreNonEmpty() {
        let models = ModelCatalogCache.codexOAuthModels()
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.contains(where: { $0.id.contains("gpt") || $0.id.contains("o") }))
    }

    func testCatalogCacheRoundtrip() {
        let models = [CatalogModel(id: "test-model-1", supportsTools: true)]
        ModelCatalogCache.save(presetId: "unit-test-cache", models: models)
        let loaded = ModelCatalogCache.load(presetId: "unit-test-cache")
        XCTAssertEqual(loaded?.first?.id, "test-model-1")
    }

    func testModalitySlotsIndependentOfChat() {
        var settings = ProviderSettings()
        settings.presetId = "anthropic"
        settings.model = "claude-sonnet-4-5"
        settings.imagePresetId = "openai"
        settings.imageModel = "gpt-image-1"
        settings.videoPresetId = "openrouter"
        settings.videoModel = "openai/sora"
        XCTAssertEqual(settings.activePresetId(for: .chat), "anthropic")
        XCTAssertEqual(settings.activePresetId(for: .image), "openai")
        XCTAssertEqual(settings.activePresetId(for: .video), "openrouter")
        XCTAssertEqual(settings.model(for: .image), "gpt-image-1")
        XCTAssertEqual(settings.model(for: .video), "openai/sora")
    }


    func testEnrichVisionFlags() {
        var settings = ProviderSettings()
        settings.presetId = "openai"
        let m = ModelCatalogService.enrich(id: "gpt-4o", name: nil, settings: settings, mediaGenerationLikely: false)
        XCTAssertTrue(m.supportsVision)
        XCTAssertTrue(m.supportsTools)
        XCTAssertTrue(m.subtitle.contains("Vision"))
    }

    func testParseOpenAIShapeViaConnectionProbeStillWorks() {
        let json = #"{"data":[{"id":"a"},{"id":"b"}]}"#.data(using: .utf8)!
        let result = ConnectionProbe.parseModelsList(data: json, statusCode: 200)
        if case .success(let ids) = result {
            XCTAssertEqual(ids, ["a", "b"])
        } else {
            XCTFail("expected success")
        }
    }

    func testIsLikelyChatModelKeepsChatHidesSpecialised() {
        // Chat models stay.
        for id in ["gpt-4.1", "gpt-4o", "gpt-5", "o3-mini", "claude-sonnet-4-5",
                   "grok-3", "gpt-4-vision-preview"] {
            XCTAssertTrue(ModelCatalogService.isLikelyChatModel(id: id), id)
        }
        // Specialised (non-chat) ids are filtered out of the chat picker.
        for id in ["text-embedding-3-large", "whisper-1", "tts-1", "gpt-4o-mini-tts",
                   "gpt-4o-audio-preview", "gpt-4o-realtime-preview", "dall-e-3",
                   "gpt-image-1", "omni-moderation-latest"] {
            XCTAssertFalse(ModelCatalogService.isLikelyChatModel(id: id), id)
        }
    }
}
