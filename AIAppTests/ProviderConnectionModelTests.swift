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
}
