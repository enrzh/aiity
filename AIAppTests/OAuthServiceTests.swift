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
        XCTAssertEqual(ProviderPreset.preset(for: "xai").oauth?.flow, .pasteCode)
        XCTAssertEqual(ProviderPreset.preset(for: "openai").oauth?.flow, .pasteCode)
        XCTAssertEqual(ProviderPreset.preset(for: "openrouter").oauth?.flow, .openRouterKeyExchange)
        XCTAssertNil(ProviderPreset.preset(for: "gemini").oauth)
        // Grok routes OAuth traffic through the CLI proxy.
        XCTAssertEqual(ProviderPreset.preset(for: "xai").oauth?.inferenceBaseURL, "https://cli-chat-proxy.grok.com/v1")
    }

    func testOpenAICodexAuthorizeMatchesRealCLI() {
        let openai = ProviderPreset.preset(for: "openai").oauth
        // The Codex swap must NOT send state in the token exchange (Claude does).
        XCTAssertEqual(openai?.stateInTokenExchange, false)
        XCTAssertEqual(ProviderPreset.preset(for: "anthropic").oauth?.stateInTokenExchange, true)
        // Full Codex scope + originator, per openai/codex build_authorize_url.
        XCTAssertTrue(openai?.scope.contains("api.connectors.read") ?? false)
        XCTAssertEqual(openai?.extraAuthParams["originator"], "codex_cli_rs")
        XCTAssertEqual(openai?.redirectURI, "http://localhost:1455/auth/callback")
    }

    func testChatGPTAccountIdFromIDToken() {
        // Build a fake JWT whose payload nests chatgpt_account_id under the
        // OpenAI auth claim.
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123"}}"#
        let jwt = "\(b64url("{}")).\(b64url(payload)).sig"
        XCTAssertEqual(OAuthService.chatGPTAccountId(fromIDToken: jwt), "acct-123")
        XCTAssertNil(OAuthService.chatGPTAccountId(fromIDToken: "not-a-jwt"))
    }

    func testGrokOAuthBaseURLOverrideOnlyForOAuthToken() {
        var settings = ProviderSettings()
        settings.presetId = "xai"
        XCTAssertEqual(settings.baseURL(forKey: "sk-plainkey"), "https://api.x.ai/v1")
        XCTAssertEqual(settings.baseURL(forKey: "oauth:tok123"), "https://cli-chat-proxy.grok.com/v1")
    }

    func testRejectsPasteboardRTFDPath() {
        let junk = "/Users/enrico/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/216D7D7D-1AAE-44D0-ABF7-4CA80138FB01/f6249efc86334592d0c38386472e18ea1b4aba54.rtfd"
        XCTAssertTrue(PlainPasteboard.looksLikePasteboardArtifact(junk))
        XCTAssertNil(PlainPasteboard.sanitize(junk))
        let parsed = OAuthService.parseAuthorizationInput(junk)
        XCTAssertTrue(parsed.code.isEmpty)
    }

    func testParseOpenAILocalhostCallbackURL() {
        let raw = "http://localhost:1455/auth/callback?code=abc123xyz&state=st1"
        let parsed = OAuthService.parseAuthorizationInput(raw)
        XCTAssertEqual(parsed.code, "abc123xyz")
        XCTAssertEqual(parsed.state, "st1")
    }

    func testParseBareQueryString() {
        let parsed = OAuthService.parseAuthorizationInput("code=tok_hello&state=s")
        XCTAssertEqual(parsed.code, "tok_hello")
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
