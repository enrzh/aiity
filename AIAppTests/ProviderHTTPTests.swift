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
}
