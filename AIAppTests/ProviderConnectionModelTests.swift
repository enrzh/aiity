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
}
