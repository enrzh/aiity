import Foundation

/// Drives one user turn: stream the model's answer, execute requested tools,
/// feed results back, repeat (bounded), and extract a generated mini-app from
/// the final answer if one is present.
@MainActor
final class ChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var busy = false
    @Published var statusLine: String?
    @Published var errorMessage: String?
    @Published var draftMiniApp: MiniAppDraft?

    /// Set when the chat continues work on a saved mini-app.
    var editingContext: (id: UUID, name: String, html: String)?

    private static let maxToolRounds = 6

    static let systemPrompt = """
    You are AI App, an assistant that chats normally AND can build small apps ("mini-apps") on request.

    When the user asks you to create or change an app, answer with a short explanation plus ONE complete, self-contained HTML document in a ```html code fence. Rules for mini-apps:
    - Single file: all CSS and JS inline. No external resources (no CDNs, fonts, images from the network) — the runtime blocks them.
    - Set a short app name in <title> and start the document with <!-- emoji: X --> where X is one fitting emoji.
    - Persist data with the bridge: `await miniapp.storage.get(key)` / `await miniapp.storage.set(key, value)` (JSON values). `miniapp.haptic()` triggers a light haptic tap.
    - Design mobile-first for an iPhone viewport, respect safe areas, support dark mode via prefers-color-scheme.

    You have web tools (web_search, fetch_url) — use them to research facts, APIs, formulas or current information before answering or building.
    Answer in the language the user writes in.
    """

    func send(_ input: String, settings: ProviderSettings) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        errorMessage = nil
        if messages.isEmpty {
            var system = Self.systemPrompt
            if let context = editingContext {
                system += "\n\nThe user is editing the existing mini-app \"\(context.name)\". Its current source:\n```html\n\(context.html)\n```\nWhen asked for changes, output the FULL updated document."
            }
            messages.append(ChatMessage(role: .system, text: system))
        }
        messages.append(ChatMessage(role: .user, text: text))
        busy = true

        let provider = settings.makeProvider(apiKey: Keychain.get("api-key-\(settings.kind.rawValue)"))
        let tools = ToolRegistry.makeTools(settings: settings)

        Task {
            await runTurn(provider: provider, tools: tools)
            busy = false
            statusLine = nil
        }
    }

    private func runTurn(provider: LLMProvider, tools: [AgentTool]) async {
        let specs = tools.map(\.spec)
        let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.spec.name, $0) })

        for _ in 0..<Self.maxToolRounds {
            messages.append(ChatMessage(role: .assistant, text: ""))
            let assistantIndex = messages.count - 1
            var requestedCalls: [ToolCallData] = []

            do {
                for try await event in provider.streamChat(messages: Array(messages[..<assistantIndex]), tools: specs) {
                    switch event {
                    case .textDelta(let delta):
                        messages[assistantIndex].text += delta
                    case .toolCall(let call):
                        requestedCalls.append(call)
                    case .done:
                        break
                    }
                }
            } catch {
                messages.remove(at: assistantIndex)
                errorMessage = error.localizedDescription
                return
            }

            messages[assistantIndex].toolCalls = requestedCalls
            if requestedCalls.isEmpty {
                draftMiniApp = MiniAppDraft.extract(from: messages[assistantIndex].text)
                return
            }

            for call in requestedCalls {
                statusLine = Self.statusText(for: call)
                let result = await toolsByName[call.name]?.run(argumentsJSON: call.argumentsJSON)
                    ?? "Error: unknown tool \(call.name)"
                messages.append(ChatMessage(role: .tool, text: result, toolCallId: call.id, toolName: call.name))
            }
            statusLine = nil
        }
        errorMessage = "Zu viele Tool-Runden — abgebrochen."
    }

    private static func statusText(for call: ToolCallData) -> String {
        let arguments = toolArguments(call.argumentsJSON)
        switch call.name {
        case "web_search": return "Sucht im Web: \(arguments["query"] as? String ?? "…")"
        case "fetch_url": return "Liest \(arguments["url"] as? String ?? "Seite")…"
        default: return "Führt \(call.name) aus…"
        }
    }

    func reset() {
        messages = []
        draftMiniApp = nil
        errorMessage = nil
        editingContext = nil
    }
}

/// A mini-app the model just produced, before the user decides to keep it.
struct MiniAppDraft: Equatable {
    var name: String
    var emoji: String
    var html: String

    static func extract(from text: String) -> MiniAppDraft? {
        guard let fenceStart = text.range(of: "```html"),
              let fenceEnd = text.range(of: "```", range: fenceStart.upperBound..<text.endIndex) else {
            return nil
        }
        let html = String(text[fenceStart.upperBound..<fenceEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard html.lowercased().contains("<html") || html.lowercased().contains("<!doctype") else { return nil }

        var name = "Mini-App"
        if let titleStart = html.range(of: "<title>", options: .caseInsensitive),
           let titleEnd = html.range(of: "</title>", options: .caseInsensitive, range: titleStart.upperBound..<html.endIndex) {
            let title = String(html[titleStart.upperBound..<titleEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { name = title }
        }
        var emoji = "✨"
        if let match = html.range(of: #"<!--\s*emoji:\s*(\S+)\s*-->"#, options: .regularExpression) {
            let comment = String(html[match])
            if let value = comment.components(separatedBy: "emoji:").last?
                .replacingOccurrences(of: "-->", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                emoji = String(value.prefix(2))
            }
        }
        return MiniAppDraft(name: name, emoji: emoji, html: html)
    }
}
