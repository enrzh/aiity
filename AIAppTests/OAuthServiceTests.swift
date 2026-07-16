import XCTest
@testable import AIApp

@MainActor
final class OAuthServiceTests: XCTestCase {

    func testPasteFlowAuthorizeURLForClaude() {
        let pending = OAuthService().startPasteFlow(preset: ProviderPreset.preset(for: "anthropic"))!
        let components = URLComponents(url: pending.authorizeURL, resolvingAgainstBaseURL: false)!
        func value(_ name: String) -> String? { components.queryItems?.first(where: { $0.name == name })?.value }
        XCTAssertEqual(components.host, "claude.ai")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("client_id"), "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(value("redirect_uri"), "https://platform.claude.com/oauth/code/callback")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code"), "true")
        XCTAssertNotNil(value("code_challenge"))
    }

    func testPasteFlowAuthorizeURLForOpenAICodex() {
        let pending = OAuthService().startPasteFlow(preset: ProviderPreset.preset(for: "openai"))!
        let url = pending.authorizeURL.absoluteString
        XCTAssertTrue(url.hasPrefix("https://auth.openai.com/oauth/authorize"))
        XCTAssertTrue(url.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
        XCTAssertTrue(url.contains("codex_cli_simplified_flow=true"))
        XCTAssertTrue(url.contains("id_token_add_organizations=true"))
    }

    func testPasteFlowAuthorizeURLForGrokUsesNonceAndPlan() {
        let pending = OAuthService().startPasteFlow(preset: ProviderPreset.preset(for: "xai"))!
        let url = pending.authorizeURL.absoluteString
        XCTAssertTrue(url.hasPrefix("https://auth.x.ai/oauth2/authorize"))
        XCTAssertTrue(url.contains("client_id=b1a00492-073a-47ea-816f-4c329264a828"))
        XCTAssertTrue(url.contains("nonce="))
        XCTAssertTrue(url.contains("plan=generic"))
    }

    func testPKCEChallengeIsStableSHA256() {
        // RFC 7636 test vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthService.s256Challenge(of: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testProviderOAuthConfiguration() {
        XCTAssertEqual(ProviderPreset.preset(for: "anthropic").oauth?.flow, .pasteCode)
        XCTAssertEqual(ProviderPreset.preset(for: "openai").oauth?.flow, .pasteCode)
        XCTAssertEqual(ProviderPreset.preset(for: "xai").oauth?.flow, .pasteCode)
        XCTAssertEqual(ProviderPreset.preset(for: "openrouter").oauth?.flow, .openRouterKeyExchange)
        XCTAssertNil(ProviderPreset.preset(for: "gemini").oauth)
        // Grok routes OAuth traffic through the CLI proxy.
        XCTAssertEqual(ProviderPreset.preset(for: "xai").oauth?.inferenceBaseURL, "https://cli-chat-proxy.grok.com/v1")
    }

    func testGrokOAuthBaseURLOverrideOnlyForOAuthToken() {
        var settings = ProviderSettings()
        settings.presetId = "xai"
        XCTAssertEqual(settings.baseURL(forKey: "sk-plainkey"), "https://api.x.ai/v1")
        XCTAssertEqual(settings.baseURL(forKey: "oauth:tok123"), "https://cli-chat-proxy.grok.com/v1")
    }

    func testOAuthCredentialRoundtripsThroughDecoder() {
        let credential = OAuthCredential(accessToken: "tok", refreshToken: "ref", expiresAt: Date(timeIntervalSince1970: 1_000_000))
        let data = try! JSONEncoder().encode(credential)
        let decoded = try! JSONDecoder().decode(OAuthCredential.self, from: Data(data))
        XCTAssertEqual(decoded, credential)
        // A stored credential is recognizable as JSON, a raw API key is not.
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("{"))
    }
}
