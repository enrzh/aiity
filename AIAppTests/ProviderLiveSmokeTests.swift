import XCTest
@testable import AIApp

/// TIER 2 — live smoke against the real hosted providers, gated on
/// per-provider keys. Without a key a test SKIPS (the suite stays green in
/// CI — that is by design); with one it runs the exact probe the in-app
/// "Verbindung testen" button runs: live models list + one short test chat.
///
/// Key naming: `AIITY_TEST_KEY_<PRESETID>` (preset id uppercased), e.g.
/// `AIITY_TEST_KEY_ANTHROPIC`, `AIITY_TEST_KEY_GROQ`. xcodebuild only forwards
/// host env vars to the test runner with the `TEST_RUNNER_` prefix:
///
///     TEST_RUNNER_AIITY_TEST_KEY_GROQ=gsk_… xcodebuild test … -only-testing:AIAppTests/ProviderLiveSmokeTests
///
/// These calls cost money and can hit rate limits — run them nightly or
/// pre-release, never in the per-commit gate. The Anthropic smoke needs a
/// PLAIN API key: subscription OAuth tokens are rate-limited outside Claude
/// Code and would flake here. See docs/provider-test-matrix.md for which keys
/// are provisioned (currently: none).
final class ProviderLiveSmokeTests: XCTestCase {

    private func runLiveSmoke(_ presetId: String) async throws {
        let envKey = "AIITY_TEST_KEY_" + presetId.uppercased()
        guard let key = ProcessInfo.processInfo.environment[envKey],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("\(envKey) nicht gesetzt — Live-Smoke für \(presetId) übersprungen.")
        }
        var settings = ProviderSettings()
        settings.presetId = presetId
        let result = await ConnectionProbe.test(settings: settings, apiKey: key)
        XCTAssertTrue(result.ok, "\(presetId): \(result.reason)")
        XCTAssertFalse(result.models.isEmpty, "\(presetId): Modell-Liste leer")
    }

    func testLiveSmokeAnthropic() async throws { try await runLiveSmoke("anthropic") }
    func testLiveSmokeOpenAI() async throws { try await runLiveSmoke("openai") }
    func testLiveSmokeOpenRouter() async throws { try await runLiveSmoke("openrouter") }
    func testLiveSmokeGemini() async throws { try await runLiveSmoke("gemini") }
    func testLiveSmokeMistral() async throws { try await runLiveSmoke("mistral") }
    func testLiveSmokeGroq() async throws { try await runLiveSmoke("groq") }
    func testLiveSmokeDeepSeek() async throws { try await runLiveSmoke("deepseek") }
    func testLiveSmokeXAI() async throws { try await runLiveSmoke("xai") }
    func testLiveSmokeTogether() async throws { try await runLiveSmoke("together") }
}
