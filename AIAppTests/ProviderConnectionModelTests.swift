import XCTest
@testable import AIApp

final class ProviderConnectionModelTests: XCTestCase {
    func testLocalProviderUsesOnDeviceStatus() {
        let preset = ProviderPreset.preset(for: "mlx")
        XCTAssertEqual(
            ProviderConnectionModel.statusText(for: preset, accountCount: 0),
            "On-Device"
        )
    }

    func testConnectedProviderUsesAccountCount() {
        let preset = ProviderPreset.preset(for: "openrouter")
        XCTAssertEqual(
            ProviderConnectionModel.statusText(for: preset, accountCount: 2),
            "2 Konten"
        )
    }

    /// Providers without a usable subscription login must not advertise one.
    func testKeyOnlyProvidersAdvertiseKeyOnly() {
        for id in ["openai", "xai", "gemini"] {
            XCTAssertEqual(
                ProviderConnectionModel.statusText(for: ProviderPreset.preset(for: id), accountCount: 0),
                "API-Key",
                id
            )
        }
    }

    // MARK: - Exit prompt trigger (needsModelChoice)

    private func needs(
        _ presetId: String,
        modality: ModelModality = .chat,
        isChatActive: Bool = true,
        committedModel: String = "",
        accountCount: Int = 1
    ) -> Bool {
        ProviderConnectionModel.needsModelChoice(
            preset: ProviderPreset.preset(for: presetId),
            modality: modality,
            isChatActive: isChatActive,
            committedModel: committedModel,
            accountCount: accountCount
        )
    }

    /// The core case: active chat provider, connected, nothing committed.
    func testActiveConnectedProviderWithoutModelPrompts() {
        XCTAssertTrue(needs("openrouter"))
        XCTAssertTrue(needs("anthropic"))
    }

    /// Presets with an EMPTY defaultModel prompt too — empty is a deliberate
    /// "unchosen" state, never backfilled with an invented fallback.
    func testEmptyDefaultPresetsPromptInsteadOfInventingAFallback() {
        XCTAssertTrue(needs("sub2api"))
        XCTAssertTrue(needs("custom-openai"))
    }

    /// Keyless local runtimes count as "connected enough" without an account.
    func testKeylessLocalRuntimePromptsWithoutAnAccount() {
        XCTAssertTrue(needs("ollama", accountCount: 0))
        XCTAssertTrue(needs("lmstudio", accountCount: 0))
    }

    /// A committed model answers the question — no prompt.
    func testACommittedModelSilencesThePrompt() {
        XCTAssertFalse(needs("openrouter", committedModel: "openai/gpt-4o-mini"))
    }

    /// Whitespace is not a choice.
    func testWhitespaceOnlyModelStillCountsAsUnchosen() {
        XCTAssertTrue(needs("openrouter", committedModel: "   "))
    }

    /// Merely BROWSING a provider that is not the active chat slot never
    /// prompts — the user did nothing that needs answering.
    func testNonActiveProviderNeverPrompts() {
        XCTAssertFalse(needs("openrouter", isChatActive: false))
    }

    /// A key-needing provider with no account is not connected — the missing
    /// account is the real gap there, not the model.
    func testUnconnectedKeyProviderDoesNotPrompt() {
        XCTAssertFalse(needs("openrouter", accountCount: 0))
        XCTAssertFalse(needs("anthropic", accountCount: 0))
    }

    /// MLX reads localModelId, not model — an empty `model` is normal there.
    func testMLXNeverPrompts() {
        XCTAssertFalse(needs("mlx", accountCount: 0))
        XCTAssertFalse(needs("mlx", accountCount: 1))
    }

    /// Image modality keeps its own auto-pick flow; the prompt is chat-only.
    func testImageModalityNeverPrompts() {
        XCTAssertFalse(needs("openai", modality: .image))
    }

    /// The catalog must always offer at least one path we have actually run.
    func testVerifiedTierIsNotEmpty() {
        let verified = ProviderPreset.catalog(maturity: .verified).map(\.id)
        XCTAssertFalse(verified.isEmpty)
        XCTAssertTrue(verified.contains("sub2api"))
        XCTAssertTrue(verified.contains("openrouter"))
    }

    // MARK: - Transactional onboarding candidate

    func testCandidateRejectsMissingRequiredKey() {
        let result = ProviderConnectionModel.makeCandidate(
            preset: ProviderPreset.preset(for: "openai"),
            baseURL: "",
            model: "gpt-4o-mini",
            apiKey: "   "
        )

        XCTAssertEqual(result.failureValue, .keyRequired)
    }

    func testCandidateRejectsMissingRequiredModel() {
        let result = ProviderConnectionModel.makeCandidate(
            preset: ProviderPreset.preset(for: "custom-openai"),
            baseURL: "api.example.com",
            model: "\n\t",
            apiKey: "sk-test"
        )

        XCTAssertEqual(result.failureValue, .modelRequired)
    }

    func testCandidateRejectsEmptyEditableURL() {
        let result = ProviderConnectionModel.makeCandidate(
            preset: ProviderPreset.preset(for: "custom-openai"),
            baseURL: "  ",
            model: "manual-model",
            apiKey: "sk-test"
        )

        XCTAssertEqual(result.failureValue, .baseURLRequired)
    }

    func testCandidateRejectsInvalidEditableURL() {
        let result = ProviderConnectionModel.makeCandidate(
            preset: ProviderPreset.preset(for: "custom-openai"),
            baseURL: "not a url",
            model: "manual-model",
            apiKey: "sk-test"
        )

        XCTAssertEqual(result.failureValue, .baseURLInvalid)
    }

    func testCandidateNormalizesURLAndModel() throws {
        let candidate = try XCTUnwrap(
            ProviderConnectionModel.makeCandidate(
                preset: ProviderPreset.preset(for: "custom-openai"),
                baseURL: " api.example.com/chat/completions?debug=true/ ",
                model: "  manual-model  ",
                apiKey: " sk-test "
            ).successValue
        )

        XCTAssertEqual(candidate.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(candidate.model, "manual-model")
        XCTAssertEqual(candidate.apiKey, "sk-test")
    }

    func testValidationFailurePreservesExistingSettings() {
        var existing = ProviderSettings()
        existing.presetId = "openrouter"
        existing.baseURL = "https://working.example/v1"
        existing.model = "working-model"
        let before = existing

        let result = ProviderConnectionModel.makeCandidate(
            preset: ProviderPreset.preset(for: "custom-openai"),
            baseURL: "",
            model: "new-model",
            apiKey: "sk-new"
        )

        XCTAssertEqual(result.failureValue, .baseURLRequired)
        XCTAssertEqual(existing, before)
    }

    func testProbeFailureDoesNotProduceCommit() {
        let candidate = try! XCTUnwrap(
            ProviderConnectionModel.makeCandidate(
                preset: ProviderPreset.preset(for: "custom-openai"),
                baseURL: "api.example.com",
                model: "manual-model",
                apiKey: "sk-new"
            ).successValue
        )

        XCTAssertFalse(ProviderConnectionModel.shouldCommit(candidate: candidate, probe: .failure("offline")))
    }
}

private extension Result {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    var failureValue: Failure? {
        guard case .failure(let value) = self else { return nil }
        return value
    }
}
