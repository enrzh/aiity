import XCTest
@testable import AIApp

final class OAuthServiceTests: XCTestCase {

    func testStandardPKCEAuthorizeURL() {
        let config = ProviderPreset.preset(for: "anthropic").oauth!
        let url = OAuthService.buildAuthorizeURL(config: config, clientId: "client-123", state: "st4te", verifier: "v3rifier")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        XCTAssertEqual(url.host, "claude.ai")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("client_id"), "client-123")
        XCTAssertEqual(value("redirect_uri"), "aiapp://oauth/anthropic")
        XCTAssertEqual(value("state"), "st4te")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), OAuthService.s256Challenge(of: "v3rifier"))
        XCTAssertNotNil(value("scope"))
    }

    func testOpenRouterAuthorizeURL() {
        let config = ProviderPreset.preset(for: "openrouter").oauth!
        let url = OAuthService.buildAuthorizeURL(config: config, clientId: "", state: "s", verifier: "v")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(url.host, "openrouter.ai")
        XCTAssertEqual(items.first(where: { $0.name == "callback_url" })?.value, "aiapp://oauth/openrouter")
        XCTAssertNil(items.first(where: { $0.name == "client_id" }))
        XCTAssertEqual(items.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
    }

    func testPKCEChallengeIsStableSHA256() {
        // RFC 7636 test vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthService.s256Challenge(of: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testProvidersWithoutOAuthHaveNoConfig() {
        XCTAssertNil(ProviderPreset.preset(for: "openai").oauth)
        XCTAssertNil(ProviderPreset.preset(for: "xai").oauth)
        XCTAssertNil(ProviderPreset.preset(for: "gemini").oauth)
        XCTAssertNotNil(ProviderPreset.preset(for: "anthropic").oauth)
        XCTAssertNotNil(ProviderPreset.preset(for: "openrouter").oauth)
    }

    func testAnthropicOAuthNeedsClientIdOpenRouterDoesNot() {
        XCTAssertTrue(ProviderPreset.preset(for: "anthropic").oauth!.needsClientId)
        XCTAssertFalse(ProviderPreset.preset(for: "openrouter").oauth!.needsClientId)
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
