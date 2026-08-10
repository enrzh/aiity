import XCTest
@testable import AIApp

final class ProviderHTTPTests: XCTestCase {

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
}
