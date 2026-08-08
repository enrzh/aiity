import XCTest
@testable import AIApp

/// Per-preset invariants over the whole provider catalog. Every entry rides
/// the same two wire dialects, so checking id integrity, endpoint building and
/// request construction here mechanically covers the presets no live key has
/// ever exercised — the only thing that differs between them is this data.
final class ProviderPresetCatalogTests: XCTestCase {

    private let catalog = ProviderPreset.catalog

    /// Representative base URL for a preset: its fixed default, or a plausible
    /// self-hosted address for the BYO-URL presets (empty default).
    private func sampleBase(for preset: ProviderPreset) -> String {
        let raw = preset.defaultBaseURL.isEmpty ? "http://192.168.1.10:8090" : preset.defaultBaseURL
        return ProviderSettings.normalizeBaseURL(raw, dialect: preset.dialect)
    }

    // MARK: - Identity

    func testPresetIdsAreUniqueAndNonEmpty() {
        let ids = catalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate preset ids: \(ids)")
        XCTAssertFalse(ids.contains(""), "empty preset id")
        for preset in catalog {
            XCTAssertFalse(preset.label.isEmpty, "\(preset.id) has no label")
        }
    }

    /// The 16 shipped presets stay addressable by their known ids — a removed
    /// or renamed id silently breaks stored settings that reference it.
    func testKnownPresetIdsResolve() {
        let expected = ["anthropic", "openai", "openrouter", "gemini", "mistral",
                        "groq", "deepseek", "xai", "together", "ollama", "lmstudio",
                        "localai", "sub2api", "custom-openai", "custom-anthropic", "mlx"]
        for id in expected {
            XCTAssertEqual(ProviderPreset.preset(for: id).id, id, "missing preset \(id)")
        }
    }

    // MARK: - Endpoint building (both wire dialects)

    /// Every preset that talks HTTP must be able to name its models endpoint;
    /// only on-device MLX legitimately has none.
    func testEveryNonMLXPresetHasAModelsListURL() {
        for preset in catalog where preset.dialect != .mlx {
            let url = ConnectionProbe.modelsListURL(base: sampleBase(for: preset), dialect: preset.dialect)
            XCTAssertNotNil(url, "\(preset.id): no models-list URL")
            XCTAssertFalse((url?.absoluteString ?? "").contains("/v1/v1"),
                           "\(preset.id) doubled /v1: \(url?.absoluteString ?? "")")
        }
        XCTAssertNil(ConnectionProbe.modelsListURL(base: "", dialect: .mlx))
    }

    /// The probe's test-chat request must build for both wire dialects, with
    /// the right endpoint per dialect; MLX deliberately builds none.
    func testCompletionRequestBuildsForBothWireDialects() throws {
        for preset in catalog {
            let request = ConnectionProbe.completionRequest(
                base: sampleBase(for: preset), dialect: preset.dialect,
                model: "test-model", apiKey: "test-key"
            )
            switch preset.dialect {
            case .mlx:
                XCTAssertNil(request, "\(preset.id): mlx has no HTTP completion")
            case .openai:
                let url = try XCTUnwrap(request?.url?.absoluteString, preset.id)
                XCTAssertTrue(url.hasSuffix("/chat/completions"), "\(preset.id): \(url)")
                XCTAssertFalse(url.contains("/v1/v1"), "\(preset.id) doubled /v1: \(url)")
                XCTAssertEqual(request?.httpMethod, "POST", preset.id)
            case .anthropic:
                let url = try XCTUnwrap(request?.url?.absoluteString, preset.id)
                XCTAssertTrue(url.hasSuffix("/v1/messages"), "\(preset.id): \(url)")
                XCTAssertEqual(request?.httpMethod, "POST", preset.id)
            }
        }
    }

    // MARK: - needsKey / editableBaseURL / oauth consistency

    /// OAuth is only carried where the flow really yields a usable credential,
    /// and both of those are key-based providers with complete configs.
    func testOAuthConfigConsistency() {
        for preset in catalog {
            guard let oauth = preset.oauth else { continue }
            XCTAssertTrue(preset.needsKey, "\(preset.id): OAuth on a keyless preset")
            XCTAssertTrue(oauth.authorizeURL.hasPrefix("https://"), preset.id)
            XCTAssertFalse(oauth.tokenURL.isEmpty, preset.id)
            XCTAssertFalse(oauth.redirectURI.isEmpty, preset.id)
        }
        // Subscription logins that require impersonating another CLI are
        // deliberately absent (OpenAI/Grok) — only these two carry OAuth.
        XCTAssertEqual(Set(catalog.filter { $0.oauth != nil }.map(\.id)),
                       ["anthropic", "openrouter"])
    }

    /// A fixed (non-editable) endpoint must actually exist — and be https when
    /// an API key travels to it. An empty default is only allowed when the
    /// user can type their own address.
    func testBaseURLEditabilityConsistency() {
        for preset in catalog where preset.dialect != .mlx {
            if preset.defaultBaseURL.isEmpty {
                XCTAssertTrue(preset.editableBaseURL,
                              "\(preset.id): no default URL and no way to enter one")
            }
            if !preset.editableBaseURL {
                XCTAssertFalse(preset.defaultBaseURL.isEmpty, preset.id)
            }
            if !preset.editableBaseURL, preset.needsKey {
                XCTAssertTrue(preset.defaultBaseURL.hasPrefix("https://"),
                              "\(preset.id): fixed keyed endpoint must be https")
            }
        }
    }

    /// Keyless presets must be reachable without an account: on-device, or a
    /// user-supplied server address.
    func testKeylessPresetsAreLocalStyleOrOnDevice() {
        for preset in catalog where !preset.needsKey {
            XCTAssertTrue(preset.dialect == .mlx || preset.editableBaseURL, preset.id)
        }
    }

    /// MLX is on-device: no key, no server, no OAuth.
    func testMLXPresetIsFullyLocal() {
        let mlx = ProviderPreset.preset(for: "mlx")
        XCTAssertEqual(mlx.dialect, .mlx)
        XCTAssertFalse(mlx.needsKey)
        XCTAssertFalse(mlx.editableBaseURL)
        XCTAssertNil(mlx.oauth)
        XCTAssertTrue(mlx.defaultBaseURL.isEmpty)
    }

    // MARK: - Cross-references into other subsystems

    /// Every image-capable preset id must exist in the catalog — a typo here
    /// silently kills the image slot for that provider.
    func testImagePresetIdsAreASubsetOfTheCatalog() {
        let ids = Set(catalog.map(\.id))
        XCTAssertTrue(MediaCapability.imagePresetIds.isSubset(of: ids),
                      "unknown ids: \(MediaCapability.imagePresetIds.subtracting(ids))")
    }

    /// Same guard for the local-wizard set the probe treats specially.
    func testLocalPresetIdsAreASubsetOfTheCatalog() {
        let ids = Set(catalog.map(\.id))
        XCTAssertTrue(ConnectionProbe.localPresetIds.isSubset(of: ids),
                      "unknown ids: \(ConnectionProbe.localPresetIds.subtracting(ids))")
        for id in ConnectionProbe.localPresetIds {
            XCTAssertTrue(ProviderPreset.preset(for: id).editableBaseURL,
                          "\(id): local-wizard preset without an editable address")
        }
    }

    /// `.verified` is a claim — "we ran a real request through this from the
    /// app". New entries belong here only together with that evidence
    /// (see docs/provider-test-matrix.md).
    func testVerifiedTierMatchesTheEvidenceList() {
        let verified = Set(catalog.filter(\.isVerified).map(\.id))
        XCTAssertEqual(verified, ["openrouter", "sub2api", "mlx"])
    }
}
