import XCTest
@testable import AIApp

final class Sub2APIIntegrationTests: XCTestCase {
    func testManifestDecodesCapabilitiesAndPreferredModels() throws {
        let data = Data(#"{"apiVersion":1,"serverVersion":"2.4.0","openAIBaseURL":"/v1","features":["chat","tools","images"],"models":{"chat":"claude-sonnet","image":"gpt-image-1"}}"#.utf8)
        let manifest = try JSONDecoder().decode(Sub2APIManifest.self, from: data)

        XCTAssertEqual(manifest.serverVersion, "2.4.0")
        XCTAssertEqual(manifest.features, [.chat, .tools, .images])
        XCTAssertEqual(manifest.models.chat, "claude-sonnet")
        XCTAssertEqual(manifest.models.image, "gpt-image-1")
    }

    func testManifestURLUsesGatewayRootInsteadOfV1() {
        XCTAssertEqual(
            Sub2APIIntegration.manifestURL(baseURL: "https://gateway.example/v1")?.absoluteString,
            "https://gateway.example/.well-known/aiity"
        )
    }

    func testEnrollmentPayloadAcceptsURLAndRejectsAdminCredentials() throws {
        let payload = try Sub2APIEnrollmentPayload.parse(
            "aiity://sub2api/enroll?gateway=https%3A%2F%2Fgateway.example&token=once-123&name=iPhone"
        )
        XCTAssertEqual(payload.gatewayURL, "https://gateway.example/v1")
        XCTAssertEqual(payload.enrollmentToken, "once-123")
        XCTAssertEqual(payload.deviceName, "iPhone")

        XCTAssertThrowsError(try Sub2APIEnrollmentPayload.parse(
            #"{"gateway":"https://gateway.example","adminKey":"secret"}"#
        ))
    }

    func testModelMappingPrefersManifestThenUsesConservativeNames() {
        let manifest = Sub2APIManifest(
            apiVersion: 1,
            serverVersion: nil,
            openAIBaseURL: "/v1",
            features: [.chat, .images],
            models: .init(chat: "preferred-chat", image: "preferred-image", video: nil, embedding: nil)
        )
        XCTAssertEqual(
            Sub2APIIntegration.mapModels(["other", "preferred-image", "preferred-chat"], manifest: manifest),
            .init(chat: "preferred-chat", image: "preferred-image")
        )
        XCTAssertEqual(
            Sub2APIIntegration.mapModels(["text-embedding-3", "gpt-image-1", "claude-sonnet"], manifest: nil),
            .init(chat: "claude-sonnet", image: "gpt-image-1")
        )
    }

    func testHealthStorePersistsOnlySanitizedConnectionMetadata() throws {
        let suite = "sub2api-health-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = Sub2APIHealthStore(defaults: defaults)
        store.save(.init(
            checkedAt: Date(timeIntervalSince1970: 123), ok: true,
            serverVersion: "2.4.0", latencyMilliseconds: 42,
            modelCount: 3, failedStage: nil, message: "Connected"
        ))

        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.serverVersion, "2.4.0")
        XCTAssertEqual(saved.latencyMilliseconds, 42)
        let bytes = try XCTUnwrap(defaults.data(forKey: Sub2APIHealthStore.storageKey))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).localizedCaseInsensitiveContains("key"))
    }
}
