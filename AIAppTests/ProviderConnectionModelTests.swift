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

    func testMLXCandidateAllowsEmptyRemoteModelAndKeepsLocalModelPath() throws {
        let candidate = try XCTUnwrap(
            ProviderConnectionModel.makeCandidate(
                preset: ProviderPreset.preset(for: "mlx"),
                baseURL: "",
                model: "",
                apiKey: ""
            ).successValue
        )

        XCTAssertTrue(candidate.model.isEmpty)
        XCTAssertEqual(candidate.localModelId, LocalModel.defaultId)
    }

    func testImageProbeUsesCandidateImageModelInsteadOfChatModel() throws {
        var existing = ProviderSettings()
        existing.presetId = "openrouter"
        existing.model = "chat-model"
        existing.imagePresetId = "openrouter"
        existing.imageModel = "old-image-model"
        let candidate = try XCTUnwrap(
            ProviderConnectionModel.makeCandidate(
                preset: ProviderPreset.preset(for: "custom-openai"),
                baseURL: "api.example.com",
                model: "new-image-model",
                apiKey: "sk-test"
            ).successValue
        )

        let probeSettings = ProviderConnectionModel.probeSettings(
            candidate: candidate,
            current: existing,
            modality: .image
        )

        XCTAssertEqual(probeSettings.model, "new-image-model")
        XCTAssertEqual(probeSettings.imageModel, "new-image-model")
    }

    func testCrossLinksUseTransactionalProbeWithTheTargetModalityAndModel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "AIApp/Views/Connections/ProviderConnectionView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("settingsStore.useForChat(presetId)"))
        XCTAssertFalse(source.contains("settingsStore.useForImage(presetId)"))
        XCTAssertTrue(
            source.contains(
                "runProbe(for: .chat, model: ProviderProfiles.profile(for: presetId).model)"
            )
        )
        XCTAssertTrue(
            source.contains(
                "runProbe(for: .image, model: imageModel.isEmpty ? ModelModality.image.defaultModel : imageModel)"
            )
        )
        XCTAssertTrue(source.contains("commit(candidate, label: label, modality: probeModality)"))
    }

    func testValidationFailureLeavesStatefulStoreUntouched() throws {
        var existingSettings = ProviderSettings()
        existingSettings.presetId = "openrouter"
        existingSettings.baseURL = "https://working.example/v1"
        existingSettings.model = "working-model"
        var existingProfile = ProviderProfile()
        existingProfile.baseURL = "https://working.example/v1"
        existingProfile.model = "working-model"
        var store = ProviderConnectionStateSpy(
            settings: existingSettings,
            profile: existingProfile,
            key: "sk-existing"
        )
        let before = store
        let result = store.attempt(
            preset: ProviderPreset.preset(for: "custom-openai"),
            baseURL: "",
            model: "new-model",
            apiKey: "sk-new",
            probe: ConnectionProbeResult(ok: true, models: [], reason: "should not run", toolsLikely: false, chatOnly: false),
            stagedKey: "sk-new",
            modality: .chat
        )

        guard case .failure = result else {
            return XCTFail("invalid candidate should fail before the store is touched")
        }
        XCTAssertEqual(store, before)
        XCTAssertEqual(store.commitCount, 0)
    }

    func testProbeFailureLeavesStatefulStoreUntouched() throws {
        var existingSettings = ProviderSettings()
        existingSettings.presetId = "openrouter"
        existingSettings.baseURL = "https://working.example/v1"
        existingSettings.model = "working-model"
        var existingProfile = ProviderProfile()
        existingProfile.baseURL = "https://working.example/v1"
        existingProfile.model = "working-model"
        var store = ProviderConnectionStateSpy(
            settings: existingSettings,
            profile: existingProfile,
            key: "sk-existing"
        )
        let before = store

        let result = store.attempt(
            preset: ProviderPreset.preset(for: "custom-openai"),
            baseURL: "api.example.com",
            model: "manual-model",
            apiKey: "sk-new",
            probe: .failure("offline"),
            stagedKey: "sk-new",
            modality: .chat
        )

        XCTAssertNotNil(result.successValue)
        XCTAssertEqual(store, before)
        XCTAssertEqual(store.commitCount, 0)
    }

    func testSuccessfulCommitStoresNormalizedURLModelAndKeyExactlyOnce() throws {
        var existingSettings = ProviderSettings()
        existingSettings.presetId = "openrouter"
        existingSettings.baseURL = "https://working.example/v1"
        existingSettings.model = "working-model"
        var existingProfile = ProviderProfile()
        existingProfile.baseURL = "https://working.example/v1"
        existingProfile.model = "working-model"
        var store = ProviderConnectionStateSpy(
            settings: existingSettings,
            profile: existingProfile,
            key: "sk-existing"
        )

        let result = store.attempt(
            preset: ProviderPreset.preset(for: "custom-openai"),
            baseURL: " api.example.com/chat/completions?debug=true/ ",
            model: "  manual-model  ",
            apiKey: " sk-new ",
            probe: ConnectionProbeResult(ok: true, models: ["manual-model"], reason: "ok", toolsLikely: true, chatOnly: false),
            stagedKey: " sk-new ",
            modality: .chat
        )

        XCTAssertNotNil(result.successValue)
        XCTAssertEqual(store.commitCount, 1)
        XCTAssertEqual(store.settings.presetId, "custom-openai")
        XCTAssertEqual(store.settings.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(store.settings.model, "manual-model")
        XCTAssertEqual(store.profile.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(store.profile.model, "manual-model")
        XCTAssertEqual(store.key, "sk-new")
    }

    func testCommitStateUsesTheCredentialSnapshotCapturedForTheProbe() throws {
        let candidate = try XCTUnwrap(
            ProviderConnectionModel.makeCandidate(
                preset: ProviderPreset.preset(for: "custom-openai"),
                baseURL: "api.example.com",
                model: "probed-model",
                apiKey: "sk-probed",
                credentialSnapshot: .apiKey("sk-probed")
            ).successValue
        )

        let state = ProviderConnectionModel.commitState(
            candidate: candidate,
            currentSettings: ProviderSettings(),
            currentProfile: ProviderProfile(),
            modality: .chat
        )

        XCTAssertEqual(state.credentialSnapshot, .apiKey("sk-probed"))
    }

    func testCandidatePreservesOAuthCredentialSnapshotThroughCommitState() throws {
        var oauth = OAuthCredential(
            accessToken: "oauth-access",
            refreshToken: "oauth-refresh",
            expiresAt: Date(timeIntervalSince1970: 123),
            accountId: "account-1"
        )
        let capturedOAuth = oauth
        let candidate = try XCTUnwrap(
            ProviderConnectionModel.makeCandidate(
                preset: ProviderPreset.preset(for: "anthropic"),
                baseURL: "",
                model: "claude-model",
                apiKey: AuthStore.oauthMarker + oauth.accessToken,
                credentialSnapshot: ProviderConnectionModel.credentialSnapshot(
                    apiKey: "",
                    pendingOAuthCredential: oauth
                )
            ).successValue
        )
        oauth.accessToken = "mutated-after-probe"

        let state = ProviderConnectionModel.commitState(
            candidate: candidate,
            currentSettings: ProviderSettings(),
            currentProfile: ProviderProfile(),
            modality: .chat
        )

        XCTAssertEqual(candidate.credentialSnapshot, .oauth(capturedOAuth))
        XCTAssertEqual(state.credentialSnapshot, .oauth(capturedOAuth))
    }

    func testAPIKeySnapshotReplacesPendingOAuthDraft() throws {
        let oauth = OAuthCredential(
            accessToken: "stale-oauth",
            refreshToken: "refresh",
            expiresAt: nil,
            accountId: nil
        )
        let snapshot = ProviderConnectionModel.credentialSnapshot(
            apiKey: " sk-replacement ",
            pendingOAuthCredential: oauth
        )
        let candidate = try XCTUnwrap(
            ProviderConnectionModel.makeCandidate(
                preset: ProviderPreset.preset(for: "anthropic"),
                baseURL: "",
                model: "replacement-model",
                apiKey: " sk-replacement ",
                credentialSnapshot: snapshot
            ).successValue
        )

        let state = ProviderConnectionModel.commitState(
            candidate: candidate,
            currentSettings: ProviderSettings(),
            currentProfile: ProviderProfile(),
            modality: .chat
        )

        XCTAssertEqual(snapshot, .apiKey("sk-replacement"))
        XCTAssertEqual(state.credentialSnapshot, .apiKey("sk-replacement"))
        XCTAssertNil(
            ProviderConnectionModel.pendingOAuthCredentialAfterCommit(
                current: oauth,
                credentialSnapshot: state.credentialSnapshot
            )
        )
    }

    func testProviderFormDisablesDraftControlsAtTheFormBoundaryWhileProbing() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "AIApp/Views/Connections/ProviderConnectionView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let disabled = try XCTUnwrap(source.range(of: ".disabled(probing)"))
        let title = try XCTUnwrap(source.range(of: ".navigationTitle", range: disabled.upperBound..<source.endIndex))
        XCTAssertLessThan(disabled.lowerBound, title.lowerBound)
    }
}

private struct ProviderConnectionStateSpy: Equatable {
    var settings: ProviderSettings
    var profile: ProviderProfile
    var key: String
    var commitCount = 0

    @discardableResult
    mutating func attempt(
        preset: ProviderPreset,
        baseURL: String,
        model: String,
        apiKey: String,
        probe: ConnectionProbeResult,
        stagedKey: String,
        modality: ModelModality
    ) -> Result<ProviderConnectionCandidate, ProviderConnectionValidationError> {
        let result = ProviderConnectionModel.makeCandidate(
            preset: preset,
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            credentialSnapshot: stagedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : .apiKey(stagedKey.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        if case .success(let candidate) = result {
            commit(
                candidate: candidate,
                probe: probe,
                modality: modality
            )
        }
        return result
    }

    private mutating func commit(
        candidate: ProviderConnectionCandidate,
        probe: ConnectionProbeResult,
        modality: ModelModality
    ) {
        guard ProviderConnectionModel.shouldCommit(candidate: candidate, probe: probe) else { return }
        let state = ProviderConnectionModel.commitState(
            candidate: candidate,
            currentSettings: settings,
            currentProfile: profile,
            modality: modality
        )
        settings = state.settings
        profile = state.profile
        if case .apiKey(let key) = state.credentialSnapshot { self.key = key }
        commitCount += 1
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
