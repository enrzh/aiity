import XCTest
@testable import AIApp

final class MCPServiceTests: XCTestCase {
    func testGoogleTemplatesRequireAUserDeployedEndpoint() {
        XCTAssertEqual(MCPServerProfile.templates.count, 4)
        XCTAssertTrue(MCPServerProfile.templates.allSatisfy { $0.url.isEmpty })
        XCTAssertTrue(MCPServerProfile.templates.allSatisfy { $0.name.contains("Google") || $0.name == "Gmail" })
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
}
