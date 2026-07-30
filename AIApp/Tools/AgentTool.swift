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
    /// Chat tools always use the chat provider key. The image tool resolves its
    /// own modality slot (possibly a different provider + model).
    ///
    /// `delegating` is false for worker agents: they get the ordinary tools but
    /// never `ask_agent`, which is what keeps delegation exactly one level deep.
    static func makeTools(
        settings: ProviderSettings,
        apiKey: String,
        delegating: Bool = false
    ) async -> [AgentTool] {
        // Local Ollama/LM Studio/MLX: no tools. Tool schemas make small models
        // invent fake <tool_call>/function JSON and answer nonsense.
        guard LocalRuntimePolicy.shouldSendTools(settings) else { return [] }

        var tools: [AgentTool] = [
            WebSearchTool(settings: settings),
            // Private/LAN fetches only allowed when the chat provider is itself local.
            FetchURLTool(allowPrivateHosts: LocalRuntimePolicy.isLocal(settings)),
        ]
        if let imageRoute = await MediaRoute.resolve(modality: .image, from: settings) {
            tools.append(ImageGenerationTool(route: imageRoute))
        }
        if delegating {
            let agents = await MainActor.run { AgentStore.active() }
            if !agents.isEmpty {
                tools.append(AskAgentTool(agents: agents, chatSettings: settings))
            }
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
