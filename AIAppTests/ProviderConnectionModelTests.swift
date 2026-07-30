import XCTest
@testable import AIApp

final class ProviderConnectionModelTests: XCTestCase {
    func testLocalProviderUsesOnDeviceStatus() {
        let preset = ProviderPreset.preset(for: "mlx")
        XCTAssertEqual(
            ProviderConnectionModel.statusText(for: preset, accountCount: 0),
            "On-Device"
        )
    }

    func testConnectedProviderUsesAccountCount() {
        let preset = ProviderPreset.preset(for: "openrouter")
        XCTAssertEqual(
            ProviderConnectionModel.statusText(for: preset, accountCount: 2),
            "2 Konten"
        )
    }

    /// Providers without a usable subscription login must not advertise one.
    func testKeyOnlyProvidersAdvertiseKeyOnly() {
        for id in ["openai", "xai", "gemini"] {
            XCTAssertEqual(
                ProviderConnectionModel.statusText(for: ProviderPreset.preset(for: id), accountCount: 0),
                "API-Key",
                id
            )
        }
    }

    /// The catalog must always offer at least one path we have actually run.
    func testVerifiedTierIsNotEmpty() {
        let verified = ProviderPreset.catalog(maturity: .verified).map(\.id)
        XCTAssertFalse(verified.isEmpty)
        XCTAssertTrue(verified.contains("sub2api"))
        XCTAssertTrue(verified.contains("openrouter"))
    }
}
