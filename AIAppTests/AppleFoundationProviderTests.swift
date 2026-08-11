import XCTest
@testable import AIApp

final class AppleFoundationProviderTests: XCTestCase {
    func testAppleFoundationIsASeparateLocalProvider() {
        let preset = ProviderPreset.preset(for: "apple-foundation")
        XCTAssertEqual(preset.dialect, .foundation)
        XCTAssertFalse(preset.needsKey)
        XCTAssertFalse(preset.editableBaseURL)
        XCTAssertNotEqual(preset.id, LocalRuntimePolicy.mlxPresetId)
    }

    func testPromptKeepsRolesAndSystemInstructionsSeparate() {
        let messages = [
            ChatMessage(role: .system, text: "Be concise"),
            ChatMessage(role: .user, text: "Hello"),
            ChatMessage(role: .assistant, text: "Hi"),
            ChatMessage(role: .user, text: "Continue"),
        ]
        XCTAssertEqual(AppleFoundationProvider.instructions(from: messages), "Be concise")
        XCTAssertEqual(
            AppleFoundationProvider.prompt(from: messages),
            "User:\nHello\n\nAssistant:\nHi\n\nUser:\nContinue"
        )
    }

    func testStreamingDeltaOnlyEmitsTheNewSuffix() {
        XCTAssertEqual(AppleFoundationProvider.delta(previous: "Hello", snapshot: "Hello world"), " world")
        XCTAssertEqual(AppleFoundationProvider.delta(previous: "stale", snapshot: "replacement"), "replacement")
    }

    func testMLXCatalogMarksRecommendationsWithoutRemovingBlockedRows() {
        XCTAssertGreaterThan(LocalModel.catalog.filter(\.recommended).count, 1)
        let all = LocalModel.rows(downloadedIds: [])
        XCTAssertEqual(all, LocalModel.catalog)
        XCTAssertFalse(LocalModelGate.shortageText(
            needBytes: 2_000_000_000,
            budgetBytes: 1_000_000_000,
            physicalMemoryBytes: 4_000_000_000
        ).isEmpty)
    }
}
