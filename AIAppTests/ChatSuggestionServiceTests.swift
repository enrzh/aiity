import XCTest
@testable import AIApp

/// Issue C: when — and only when — the empty chat may ask the user's own cloud
/// provider for a couple of ideas, plus the cache and the lenient parser.
final class ChatSuggestionServiceTests: XCTestCase {

    private func cloudSettings(
        presetId: String = "openai", model: String = "gpt-4.1"
    ) -> ProviderSettings {
        var settings = ProviderSettings()
        settings.presetId = presetId
        settings.model = model
        return settings
    }

    // MARK: - Gate matrix

    func testCloudPresetWithExplicitModelAndAPIKeyIsEligible() {
        XCTAssertTrue(ChatSuggestionService.isEligible(
            settings: cloudSettings(), credential: .apiKey, enabled: true
        ))
        XCTAssertTrue(ChatSuggestionService.isEligible(
            settings: cloudSettings(presetId: "anthropic", model: "claude-sonnet-4-5"),
            credential: .apiKey, enabled: true
        ))
    }

    func testToggleOffBlocksEverything() {
        XCTAssertFalse(ChatSuggestionService.isEligible(
            settings: cloudSettings(), credential: .apiKey, enabled: false
        ))
    }

    /// The model-autoselect contract: an empty `model` is a deliberate state,
    /// and `effectiveModel`'s preset default must NOT stand in for a user pick
    /// when nobody asked for the request.
    func testEmptyModelIsNotEligibleEvenWhenThePresetHasADefault() {
        let settings = cloudSettings(model: "")
        XCTAssertFalse(settings.effectiveModel.isEmpty, "precondition: this preset has a default model")
        XCTAssertFalse(ChatSuggestionService.isEligible(
            settings: settings, credential: .apiKey, enabled: true
        ))
        XCTAssertFalse(ChatSuggestionService.isEligible(
            settings: cloudSettings(model: "   "), credential: .apiKey, enabled: true
        ))
    }

    /// Subscription OAuth is a hard exclusion: unattended traffic must not use
    /// the CLI-impersonation path, nor burn 429-prone plan quota.
    func testOAuthCredentialIsNeverEligible() {
        XCTAssertFalse(ChatSuggestionService.isEligible(
            settings: cloudSettings(presetId: "anthropic", model: "claude-sonnet-4-5"),
            credential: .oauth, enabled: true
        ))
        XCTAssertFalse(ChatSuggestionService.isEligible(
            settings: cloudSettings(presetId: "openrouter", model: "openai/gpt-4o-mini"),
            credential: .oauth, enabled: true
        ))
    }

    func testMissingCredentialIsNotEligible() {
        XCTAssertFalse(ChatSuggestionService.isEligible(
            settings: cloudSettings(), credential: .none, enabled: true
        ))
    }

    func testLocalAndOnDeviceDialectsAreNotEligible() {
        for presetId in ["mlx", "ollama", "lmstudio", "localai", "custom-openai", "sub2api"] {
            var settings = cloudSettings(presetId: presetId, model: "some-model")
            settings.baseURL = "http://127.0.0.1:1234/v1"
            XCTAssertFalse(
                ChatSuggestionService.isEligible(settings: settings, credential: .apiKey, enabled: true),
                "\(presetId) is a local runtime — the chips stay static"
            )
        }
    }

    // MARK: - Request shape

    func testRequestUsesPlainKeyAuthPerDialect() throws {
        let openai = try XCTUnwrap(ChatSuggestionService.request(
            settings: cloudSettings(), apiKey: "sk-test", prompt: "hallo"
        ))
        XCTAssertEqual(openai.httpMethod, "POST")
        XCTAssertTrue(openai.url?.absoluteString.hasSuffix("/chat/completions") == true)
        XCTAssertEqual(openai.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

        let anthropic = try XCTUnwrap(ChatSuggestionService.request(
            settings: cloudSettings(presetId: "anthropic", model: "claude-sonnet-4-5"),
            apiKey: "sk-ant", prompt: "hallo"
        ))
        XCTAssertTrue(anthropic.url?.absoluteString.hasSuffix("/v1/messages") == true)
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertNil(anthropic.value(forHTTPHeaderField: "anthropic-beta"),
                     "the OAuth beta header must never appear on unattended traffic")
        XCTAssertNil(anthropic.value(forHTTPHeaderField: "Authorization"))
    }

    func testRequestRefusesOAuthTokensAndEmptyModels() {
        XCTAssertNil(ChatSuggestionService.request(
            settings: cloudSettings(), apiKey: AuthStore.oauthMarker + "token", prompt: "hallo"
        ))
        XCTAssertNil(ChatSuggestionService.request(
            settings: cloudSettings(model: ""), apiKey: "sk-test", prompt: "hallo"
        ))
        XCTAssertNil(ChatSuggestionService.request(
            settings: cloudSettings(presetId: "mlx", model: "x"), apiKey: "sk-test", prompt: "hallo"
        ))
    }

    /// Nothing the user wrote may end up in the body — only a bucketed count.
    func testPromptCarriesNoUserContent() {
        let prompt = ChatSuggestionService.prompt(savedAppCount: 7)
        XCTAssertTrue(prompt.contains("einige"))
        XCTAssertFalse(prompt.contains("7"))
        XCTAssertEqual(ChatSuggestionService.experienceBucket(0), "noch keine")
        XCTAssertEqual(ChatSuggestionService.experienceBucket(2), "ein paar")
        XCTAssertEqual(ChatSuggestionService.experienceBucket(40), "viele")
    }

    // MARK: - Parsing

    private func openAIBody(_ content: String) -> Data {
        let object: [String: Any] = ["choices": [["message": ["content": content]]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testParsesCleanJSONArray() {
        let items = ChatSuggestionService.parse(
            openAIBody("[\"Schlaf-Tagebuch\",\"Farb-Picker\",\"Zungenbrecher\"]"), dialect: .openai
        )
        XCTAssertEqual(items, ["Schlaf-Tagebuch", "Farb-Picker", "Zungenbrecher"])
    }

    func testParsesFencedAndProseWrappedAnswers() {
        let fenced = ChatSuggestionService.parse(
            openAIBody("Klar!\n```json\n[\"Farb-Picker\", \"Zungenbrecher\"]\n```\n"), dialect: .openai
        )
        XCTAssertEqual(fenced, ["Farb-Picker", "Zungenbrecher"])

        let sloppy = ChatSuggestionService.parse(
            openAIBody("['Farb-Picker', 'Zungenbrecher']"), dialect: .openai
        )
        XCTAssertEqual(sloppy, ["Farb-Picker", "Zungenbrecher"])
    }

    func testParsesAnthropicBlocks() {
        let object: [String: Any] = ["content": [["type": "text", "text": "[\"Farb-Picker\"]"]]]
        let data = try! JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(ChatSuggestionService.parse(data, dialect: .anthropic), ["Farb-Picker"])
    }

    func testParseDropsDuplicatesOverlongAndEmptyItems() {
        let long = String(repeating: "x", count: 45)
        let items = ChatSuggestionService.parse(
            openAIBody("[\"Farb-Picker\", \"farb picker\", \"\", \"\(long)\", \"Zungenbrecher\"]"),
            dialect: .openai
        )
        XCTAssertEqual(items, ["Farb-Picker", "Zungenbrecher"])
    }

    func testParseCapsAtTheModelBudget() {
        let items = ChatSuggestionService.parse(
            openAIBody("[\"Eins\",\"Zwei\",\"Drei\",\"Vier\",\"Fünf\"]"), dialect: .openai
        )
        XCTAssertEqual(items.count, ChatSuggestions.maxModelSuggestions)
    }

    func testGarbageParsesToNothing() {
        XCTAssertTrue(ChatSuggestionService.parse(Data("not json".utf8), dialect: .openai).isEmpty)
        XCTAssertTrue(ChatSuggestionService.parse(openAIBody("Ich kann das leider nicht."), dialect: .openai).isEmpty)
        XCTAssertTrue(ChatSuggestionService.parse(openAIBody("[]"), dialect: .openai).isEmpty)
    }

    // MARK: - Cache

    private func scratchDefaults() throws -> UserDefaults {
        let name = "chat-suggestion-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    func testCacheRoundTripAndTTL() throws {
        let defaults = try scratchDefaults()
        let saved = Date()
        ChatSuggestionService.store(["Farb-Picker"], presetId: "openai", model: "gpt-4.1",
                                    now: saved, defaults: defaults)

        XCTAssertEqual(
            ChatSuggestionService.cached(presetId: "openai", model: "gpt-4.1",
                                        now: saved.addingTimeInterval(3600), defaults: defaults),
            ["Farb-Picker"]
        )
        XCTAssertNil(ChatSuggestionService.cached(
            presetId: "openai", model: "gpt-4.1",
            now: saved.addingTimeInterval(ChatSuggestionService.cacheTTL + 1), defaults: defaults
        ), "stale entries must not keep the row frozen for days")
    }

    func testCacheIsInvalidatedByProviderOrModelSwitch() throws {
        let defaults = try scratchDefaults()
        ChatSuggestionService.store(["Farb-Picker"], presetId: "openai", model: "gpt-4.1",
                                    defaults: defaults)
        XCTAssertNil(ChatSuggestionService.cached(presetId: "anthropic", model: "gpt-4.1", defaults: defaults))
        XCTAssertNil(ChatSuggestionService.cached(presetId: "openai", model: "gpt-5", defaults: defaults))
    }

    func testEmptyResultIsNeverCached() throws {
        let defaults = try scratchDefaults()
        ChatSuggestionService.store([], presetId: "openai", model: "gpt-4.1", defaults: defaults)
        XCTAssertNil(ChatSuggestionService.cached(presetId: "openai", model: "gpt-4.1", defaults: defaults))
    }
}
