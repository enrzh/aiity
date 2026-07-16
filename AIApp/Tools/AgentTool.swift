import Foundation

/// Result of a tool run: `text` goes back to the model; `mediaIds` are stored
/// media (generated images/videos) attached to the chat for the user to see.
struct ToolRunResult {
    var text: String
    var mediaIds: [String] = []

    init(_ text: String, mediaIds: [String] = []) {
        self.text = text
        self.mediaIds = mediaIds
    }
}

/// A capability the app executes natively on behalf of the model. Works with
/// every provider that supports tool calls — including local models behind an
/// OpenAI-compatible endpoint. This is what makes weak local models useful:
/// the heavy lifting (search, fetching, image/video generation) happens here.
protocol AgentTool {
    var spec: ToolSpec { get }
    func run(argumentsJSON: String) async -> ToolRunResult
}

enum ToolRegistry {
    /// `apiKey` is the resolved secret for the active account (plain key or
    /// "oauth:<token>") — image/video tools call the provider with it.
    static func makeTools(settings: ProviderSettings, apiKey: String) -> [AgentTool] {
        var tools: [AgentTool] = [
            WebSearchTool(searchEndpoint: settings.searchEndpoint),
            FetchURLTool(),
        ]
        // Generation tools need an OpenAI-compatible image/video endpoint;
        // on-device MLX has none, so only offer them for hosted providers.
        if settings.preset.dialect != .mlx {
            tools.append(ImageGenerationTool(settings: settings, apiKey: apiKey))
            tools.append(VideoGenerationTool(settings: settings, apiKey: apiKey))
        }
        return tools
    }
}

func toolArguments(_ argumentsJSON: String) -> [String: Any] {
    jsonObject(Data(argumentsJSON.utf8)) ?? [:]
}

/// Bearer/key helper shared by the generation tools.
func bearerToken(from apiKey: String) -> String {
    apiKey.hasPrefix(AuthStore.oauthMarker) ? String(apiKey.dropFirst(AuthStore.oauthMarker.count)) : apiKey
}
