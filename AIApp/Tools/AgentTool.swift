import Foundation

/// A capability the app executes natively on behalf of the model. Works with
/// every provider that supports tool calls — including local models behind an
/// OpenAI-compatible endpoint. This is what makes weak local models useful
/// for research: the heavy lifting (search, fetching) happens in the app.
protocol AgentTool {
    var spec: ToolSpec { get }
    func run(argumentsJSON: String) async -> String
}

enum ToolRegistry {
    static func makeTools(settings: ProviderSettings) -> [AgentTool] {
        [
            WebSearchTool(searchEndpoint: settings.searchEndpoint),
            FetchURLTool(),
        ]
    }
}

func toolArguments(_ argumentsJSON: String) -> [String: Any] {
    jsonObject(Data(argumentsJSON.utf8)) ?? [:]
}
