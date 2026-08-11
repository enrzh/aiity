import XCTest
@testable import AIApp

final class MCPServiceTests: XCTestCase {
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testRecommendationsHaveHTTPSSetupLinksAndBlankDisabledDrafts() {
        XCTAssertGreaterThanOrEqual(MCPRecommendation.catalog.count, 2)
        for recommendation in MCPRecommendation.catalog {
            XCTAssertEqual(recommendation.setupURL.scheme, "https", recommendation.name)
            XCTAssertFalse(recommendation.summary.isEmpty, recommendation.name)
            let draft = recommendation.makeProfileDraft()
            XCTAssertEqual(draft.name, recommendation.name)
            XCTAssertTrue(draft.url.isEmpty)
            XCTAssertFalse(draft.enabled)
            XCTAssertTrue(draft.tools.isEmpty)
        }
    }

    func testRecommendedCatalogTeachesGoogleServicesWithoutFakeProfiles() {
        let services = Set(MCPRecommendation.catalog.flatMap(\.googleServices))
        XCTAssertTrue(services.isSuperset(of: ["Google Drive", "Google Calendar", "Gmail"]))
        XCTAssertFalse(MCPRecommendation.catalog.contains { $0.makeProfileDraft().name == "Google Drive" })
    }

    func testDiscoveredSchemaBecomesNamespacedAgentTool() {
        let profile = MCPServerProfile(name: "Google Drive", url: "https://example.com/mcp")
        let definition = MCPToolDefinition(
            name: "search_files",
            description: "Search Drive",
            inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#
        )
        let spec = MCPAgentTool(profile: profile, definition: definition).spec
        XCTAssertEqual(spec.name, "mcp_google_drive_search_files")
        XCTAssertEqual(spec.parameters["type"] as? String, "object")
        XCTAssertTrue(spec.description.contains("Search Drive"))
    }

    func testRecommendedSetupPrecedesCustomServerAndLinksToProvider() throws {
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("AIApp/Views/MCPServersView.swift"),
            encoding: .utf8
        )
        let recommended = try XCTUnwrap(source.range(of: "Section(\"Empfohlen\")"))
        let custom = try XCTUnwrap(source.range(of: "Eigener Streamable-HTTP-MCP-Server"))
        XCTAssertLessThan(recommended.lowerBound, custom.lowerBound)
        XCTAssertTrue(source.contains("Link(destination: recommendation.setupURL)"))
        XCTAssertTrue(source.contains("Section(\"Google-Dienste\")"))
        XCTAssertTrue(source.contains("profile.enabled = !profile.tools.isEmpty"))
    }
}
