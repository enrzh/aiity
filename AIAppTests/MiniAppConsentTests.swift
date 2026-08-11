import XCTest
@testable import AIApp

final class MiniAppConsentTests: XCTestCase {
    private var legacyValue: Any?
    private var recordsValue: Any?

    override func setUp() {
        super.setUp()
        legacyValue = UserDefaults.standard.object(forKey: "miniapp-consent-v1")
        recordsValue = UserDefaults.standard.object(forKey: "miniapp-consent-v2")
        UserDefaults.standard.removeObject(forKey: "miniapp-consent-v1")
        UserDefaults.standard.removeObject(forKey: "miniapp-consent-v2")
    }

    override func tearDown() {
        UserDefaults.standard.set(legacyValue, forKey: "miniapp-consent-v1")
        UserDefaults.standard.set(recordsValue, forKey: "miniapp-consent-v2")
        super.tearDown()
    }

    func testLegacyCapabilityGrantMigratesWithNoHosts() {
        UserDefaults.standard.set(["legacy-app": "network"], forKey: "miniapp-consent-v1")

        XCTAssertEqual(MiniAppConsent.granted(appId: "legacy-app"), .network)
        XCTAssertEqual(MiniAppConsent.hosts(appId: "legacy-app"), [])
        XCTAssertEqual(MiniAppConsent.grants()["legacy-app"], .network)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: "miniapp-consent-v2"))
    }

    func testHostsAreIsolatedPerApp() {
        MiniAppConsent.allow(appId: "app-a", capability: .network, hosts: ["API.Example.COM"])

        XCTAssertEqual(MiniAppConsent.hosts(appId: "app-a"), ["api.example.com"])
        XCTAssertEqual(MiniAppConsent.hosts(appId: "app-b"), [])
        XCTAssertTrue(NetworkTargetValidator.isAllowed(
            URL(string: "https://api.example.com/v1")!,
            allowPrivate: false,
            allowedHosts: MiniAppConsent.hosts(appId: "app-a")
        ))
        XCTAssertFalse(NetworkTargetValidator.isAllowed(
            URL(string: "https://api.example.com/v1")!,
            allowPrivate: false,
            allowedHosts: MiniAppConsent.hosts(appId: "app-b")
        ))
    }

    func testHostNormalizationRejectsPrivateAndMalformedTargets() {
        XCTAssertEqual(NetworkTargetValidator.normalizeHost(" HTTPS://Example.COM./path "), "example.com")
        XCTAssertEqual(NetworkTargetValidator.normalizeHost("example.com."), "example.com")
        XCTAssertNil(NetworkTargetValidator.normalizeHost("127.0.0.1"))
        XCTAssertNil(NetworkTargetValidator.normalizeHost("8.8.8.8"))
        XCTAssertNil(NetworkTargetValidator.normalizeHost("https://1.1.1.1"))
        XCTAssertNil(NetworkTargetValidator.normalizeHost("https://[2001:4860:4860::8888]"))
        XCTAssertNil(NetworkTargetValidator.normalizeHost("https://example.com:443"))
        XCTAssertNil(NetworkTargetValidator.normalizeHost("http://example.com/path with spaces"))
        XCTAssertNil(NetworkTargetValidator.normalizeHost("example.com/other"))
        XCTAssertNil(NetworkTargetValidator.normalizeHost("example\\.com"))
    }

    func testRuntimeRejectsIPLiteralAndExplicitPortEvenWhenHostIsGranted() {
        for raw in [
            "https://8.8.8.8/",
            "https://[2001:4860:4860::8888]/",
            "https://example.com:443/",
            "https://example.com:8443/"
        ] {
            let url = URL(string: raw)!
            XCTAssertFalse(
                NetworkTargetValidator.isAllowed(
                    url, allowPrivate: false, allowedHosts: [url.host ?? "8.8.8.8"]
                ),
                "mini-app runtime must refuse \(raw)"
            )
        }
    }

    func testIndividualAndAllHostRevocationPreserveCapability() {
        MiniAppConsent.allow(appId: "revoke-app", capability: .browser,
                             hosts: ["one.example", "two.example"])

        XCTAssertTrue(MiniAppConsent.revokeHost(appId: "revoke-app", host: "ONE.EXAMPLE"))
        XCTAssertEqual(MiniAppConsent.hosts(appId: "revoke-app"), ["two.example"])
        XCTAssertFalse(MiniAppConsent.revokeHost(appId: "revoke-app", host: "missing.example"))

        MiniAppConsent.revokeAllHosts(appId: "revoke-app")
        XCTAssertEqual(MiniAppConsent.hosts(appId: "revoke-app"), [])
        XCTAssertEqual(MiniAppConsent.granted(appId: "revoke-app"), .browser)
    }

    func testCapabilityUpdatePreservesExistingHosts() {
        MiniAppConsent.allow(appId: "upgrade-app", capability: .network, hosts: ["api.example"])
        MiniAppConsent.allow(appId: "upgrade-app", capability: .browser)

        XCTAssertEqual(MiniAppConsent.granted(appId: "upgrade-app"), .browser)
        XCTAssertEqual(MiniAppConsent.hosts(appId: "upgrade-app"), ["api.example"])
    }

    func testAllowUnionsNewHostsWithExistingHosts() {
        MiniAppConsent.allow(appId: "union-app", capability: .network, hosts: ["one.example"])
        MiniAppConsent.allow(appId: "union-app", capability: .network, hosts: ["two.example"])

        XCTAssertEqual(MiniAppConsent.hosts(appId: "union-app"), ["one.example", "two.example"])
    }

    func testMigrationRemovesLegacySoRevokeCannotResurrectAfterCorruptV2() {
        UserDefaults.standard.set(["legacy-app": "network"], forKey: "miniapp-consent-v1")

        XCTAssertEqual(MiniAppConsent.granted(appId: "legacy-app"), .network)
        XCTAssertNil(UserDefaults.standard.object(forKey: "miniapp-consent-v1"))

        MiniAppConsent.revoke(appId: "legacy-app")
        UserDefaults.standard.set(Data("corrupt-v2".utf8), forKey: "miniapp-consent-v2")

        XCTAssertNil(MiniAppConsent.granted(appId: "legacy-app"))
    }
}
