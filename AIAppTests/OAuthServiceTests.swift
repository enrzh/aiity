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

    /// Providers whose subscription token is only accepted by their own CLI
    /// backend must not offer an in-app sign-in — no OAuth config, so
    /// `startPasteFlow` has nothing to start.
    func testSubscriptionOnlyProvidersHaveNoOAuthFlow() {
        for id in ["openai", "xai"] {
            let preset = ProviderPreset.preset(for: id)
            XCTAssertNil(preset.oauth, "\(id) must be API-key only")
            XCTAssertNil(OAuthService().startPasteFlow(preset: preset))
        }
    }

    func testPKCEChallengeIsStableSHA256() {
        // RFC 7636 test vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthService.s256Challenge(of: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testProviderOAuthConfiguration() {
        XCTAssertEqual(ProviderPreset.preset(for: "anthropic").oauth?.flow, .pasteCode)
        XCTAssertEqual(ProviderPreset.preset(for: "openrouter").oauth?.flow, .openRouterKeyExchange)
        XCTAssertNil(ProviderPreset.preset(for: "gemini").oauth)
        // Only Claude's non-standard flow echoes code#state back in the exchange.
        XCTAssertEqual(ProviderPreset.preset(for: "anthropic").oauth?.stateInTokenExchange, true)
    }

    /// No credential type may reroute inference to a non-public backend — every
    /// preset talks to its normal endpoint regardless of key vs. OAuth token.
    func testOAuthTokenDoesNotRerouteBaseURL() {
        for id in ["anthropic", "openai", "xai", "openrouter"] {
            var settings = ProviderSettings()
            settings.presetId = id
            XCTAssertEqual(settings.baseURL(forKey: "oauth:tok"), settings.effectiveBaseURL, "\(id) rerouted")
            XCTAssertEqual(settings.baseURL(forKey: "sk-plain"), settings.effectiveBaseURL, "\(id) rerouted")
        }
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

    func testRefreshCoordinatorSingleFlight() async {
        actor Counter { var n = 0; func inc() { n += 1 }; func value() -> Int { n } }
        let counter = Counter()
        TokenRefreshCoordinator.testRefreshOverride = { _, _ in
            await counter.inc()
            try? await Task.sleep(nanoseconds: 250_000_000)  // hold the flight open
            return OAuthCredential(accessToken: "new", refreshToken: "r2", expiresAt: Date().addingTimeInterval(3600))
        }
        defer { TokenRefreshCoordinator.testRefreshOverride = nil }

        let config = ProviderPreset.preset(for: "anthropic").oauth!
        let acct = "test-refresh-\(UUID().uuidString)"
        await withTaskGroup(of: OAuthCredential?.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await TokenRefreshCoordinator.shared.refresh(
                        account: acct, config: config, refreshToken: "r1", currentAccountId: nil
                    )
                }
            }
            for await _ in group {}
        }
        let n = await counter.value()
        XCTAssertEqual(n, 1, "6 concurrent refreshes must collapse to a single network refresh")
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
