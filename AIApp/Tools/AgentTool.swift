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
/// OpenAI-compatible endpoint.
protocol AgentTool {
    var spec: ToolSpec { get }
    func run(argumentsJSON: String) async -> ToolRunResult
}

enum ToolRegistry {
    /// Chat tools always use the chat provider key. Image/video tools resolve
    /// their own modality slots (possibly a different provider + model).
    static func makeTools(settings: ProviderSettings, apiKey: String) async -> [AgentTool] {
        // Local Ollama/LM Studio/MLX: no tools. Tool schemas make small models
        // invent fake <tool_call>/function JSON and answer nonsense.
        guard LocalRuntimePolicy.shouldSendTools(settings) else { return [] }

        var tools: [AgentTool] = [
            WebSearchTool(settings: settings),
            FetchURLTool(),
        ]
        if let imageRoute = await MediaRoute.resolve(modality: .image, from: settings) {
            tools.append(ImageGenerationTool(route: imageRoute))
        }
        if let videoRoute = await MediaRoute.resolve(modality: .video, from: settings) {
            tools.append(VideoGenerationTool(route: videoRoute))
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
