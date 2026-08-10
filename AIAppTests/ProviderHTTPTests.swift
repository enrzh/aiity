import XCTest
@testable import AIApp

final class ProviderHTTPTests: XCTestCase {

    func testShortLivedCallSitesUseValidatedTransport() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let callSites = [
            sourceRoot.appendingPathComponent("AIApp/Tools/WebSearchTool.swift"),
            sourceRoot.appendingPathComponent("AIApp/Models/SkillStore.swift"),
        ]

        for file in callSites {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("URLSession.shared"), file.lastPathComponent)
            XCTAssertTrue(source.contains("ProviderHTTP.quickData"), file.lastPathComponent)
        }
    }

    func testConnectionProbeCannotBypassValidatedTransport() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let file = sourceRoot.appendingPathComponent("AIApp/Services/ConnectionProbe.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        XCTAssertFalse(source.contains("URLSession.shared"))
        XCTAssertFalse(source.contains("session.data(for:"))
        XCTAssertTrue(source.contains("ProviderHTTP.quickData"))
    }

    func testLiveProvidersUseValidatedStreamingTransport() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let callSites = [
            sourceRoot.appendingPathComponent("AIApp/Providers/OpenAICompatibleProvider.swift"),
            sourceRoot.appendingPathComponent("AIApp/Providers/AnthropicProvider.swift"),
        ]

        for file in callSites {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("ProviderHTTP.streaming."), file.lastPathComponent)
            XCTAssertTrue(source.contains("ProviderHTTP.streamingBytes"), file.lastPathComponent)
        }
    }

    func testQuickRequestRejectsPublicCleartextTargets() {
        let url = URL(string: "http://api.example.com/v1/models")!

        XCTAssertThrowsError(try ProviderHTTP.validateQuickTarget(url, allowPrivate: false)) { error in
            XCTAssertEqual(error as? NetworkTransportError, .cleartextNotAllowed(url))
        }
    }

    func testQuickRequestAllowsExplicitSelfHostedLANTarget() throws {
        let url = URL(string: "http://192.168.178.20:11434/v1/models")!

        XCTAssertNoThrow(try ProviderHTTP.validateQuickTarget(url, allowPrivate: true))
    }

    func testQuickRequestRejectsPrivateTargetWithoutSelfHostedOptIn() {
        let url = URL(string: "https://127.0.0.1:11434/v1/models")!

        XCTAssertThrowsError(try ProviderHTTP.validateQuickTarget(url, allowPrivate: false)) { error in
            XCTAssertEqual(error as? NetworkTransportError, .targetNotAllowed(url))
        }
    }

    func testQuickRequestRejectsNonHTTPSSchemesEvenForSelfHostedProviders() {
        let url = URL(string: "file:///tmp/models.json")!

        XCTAssertThrowsError(try ProviderHTTP.validateQuickTarget(url, allowPrivate: true)) { error in
            XCTAssertEqual(error as? NetworkTransportError, .targetNotAllowed(url))
        }
    }

    func testQuickRequestReportsRejectedRedirectAsTypedTransportError() async throws {
        let unsafeTarget = URL(string: "http://api.example.com/v1/models")!
        let server = try ProbeStubServer(mode: .redirect(unsafeTarget))
        defer { server.stop() }

        let request = URLRequest(url: URL(string: server.baseURL + "/redirect")!)

        do {
            _ = try await ProviderHTTP.quickData(for: request, allowPrivate: true)
            XCTFail("an unsafe redirect must be refused")
        } catch let error as NetworkTransportError {
            XCTAssertEqual(error, .unsafeRedirect(unsafeTarget))
        }
    }

    func testPrivateCapableRequestRejectsPublicToPrivateRedirect() {
        let origin = URL(string: "https://api.example.com/v1/models")!
        let redirect = URL(string: "https://127.0.0.1:11434/v1/models")!

        XCTAssertThrowsError(
            try ProviderHTTP.validateRedirectTarget(
                redirect,
                from: origin,
                allowPrivate: true
            )
        ) { error in
            XCTAssertEqual(error as? NetworkTransportError, .unsafeRedirect(redirect))
        }
    }

    func testPrivateCapableRequestAllowsSameOriginPrivateRedirect() {
        let origin = URL(string: "http://192.168.178.20:11434/v1/models")!
        let redirect = URL(string: "http://192.168.178.20:11434/api/tags")!

        XCTAssertNoThrow(
            try ProviderHTTP.validateRedirectTarget(
                redirect,
                from: origin,
                allowPrivate: true
            )
        )
    }

    func testCredentialBearingPublicRequestRejectsCrossOriginHTTPSRedirect() {
        let origin = URL(string: "https://api.example.com/v1/models")!
        let redirect = URL(string: "https://cdn.example.net/v1/models")!

        XCTAssertThrowsError(
            try ProviderHTTP.validateRedirectTarget(redirect, from: origin, allowPrivate: false)
        ) { error in
            XCTAssertEqual(error as? NetworkTransportError, .unsafeRedirect(redirect))
        }
    }

    func testCredentialBearingPublicRequestAllowsSameOriginHTTPSRedirect() {
        let origin = URL(string: "https://api.example.com/v1/models")!
        let redirect = URL(string: "https://api.example.com/v2/models")!

        XCTAssertNoThrow(
            try ProviderHTTP.validateRedirectTarget(redirect, from: origin, allowPrivate: false)
        )
    }

    func testStreamingRequestRejectsPublicCleartextInitialTarget() async {
        var request = URLRequest(url: URL(string: "http://api.example.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"secret":"prompt"}"#.utf8)

        do {
            _ = try await ProviderHTTP.streamingBytes(for: request, allowPrivate: false)
            XCTFail("public cleartext streaming must be refused before connecting")
        } catch let error as NetworkTransportError {
            XCTAssertEqual(error, .cleartextNotAllowed(request.url!))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStreamingRequestDoesNotFollowCredentialBearingCrossOriginRedirect() async throws {
        let target = try ProbeStubServer(mode: .openai)
        defer { target.stop() }
        let targetURL = URL(string: target.baseURL + "/v1/chat/completions")!
        let redirector = try ProbeStubServer(mode: .redirect(targetURL))
        defer { redirector.stop() }

        var request = URLRequest(url: URL(string: redirector.baseURL + "/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer top-secret", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"secret":"prompt"}"#.utf8)

        do {
            _ = try await ProviderHTTP.streamingBytes(for: request, allowPrivate: true)
            XCTFail("cross-origin streaming redirect must be refused")
        } catch let error as NetworkTransportError {
            XCTAssertEqual(error, .unsafeRedirect(targetURL))
        }
        XCTAssertEqual(target.requestCount, 0, "redirect target must receive neither credentials nor request body")
    }

    func testQuickRequestHonorsShortRequestTimeoutWithoutWaitingForConnectivity() async {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/v1/models")!)
        request.timeoutInterval = 0.5
        let started = ContinuousClock.now

        do {
            _ = try await ProviderHTTP.quickData(for: request, allowPrivate: true)
            XCTFail("closed localhost port must fail")
        } catch {
            XCTAssertLessThan(
                started.duration(to: .now),
                .seconds(2),
                "probe-style requests must not inherit long connectivity waits"
            )
        }
    }
}
