import Foundation

/// Runs one worker agent to completion and hands its answer back as text.
///
/// A worker is a *bounded* run, not a participant in an open conversation: it
/// receives one task, may use the ordinary tools for a few rounds, and returns
/// a final answer. It is never given `ask_agent`, so workers cannot delegate to
/// each other — that is the whole reason this can't spiral into an unbounded
/// multi-agent loop burning the user's credits while they watch.
enum SubAgentRunner {
    /// Tool rounds a worker gets before it must answer with what it has.
    static let maxToolRounds = 3
    /// Hard ceiling on what a worker hands back, so one verbose agent can't
    /// blow up the lead's context.
    static let maxReplyCharacters = 6_000

    static func run(
        agent: AgentDefinition,
        task: String,
        chatSettings: ProviderSettings
    ) async -> String {
        let settings = agent.settings(fallback: chatSettings)
        let apiKey = await AuthStore.effectiveKey(for: settings)

        if settings.preset.needsKey, apiKey.isEmpty, !ConnectionProbe.isLocalStyle(settings.presetId) {
            return String(localized: "[\(agent.name) hat kein Konto — unter Anbieter einen Key hinterlegen.]")
        }
        if settings.effectiveModel.trimmingCharacters(in: .whitespaces).isEmpty,
           settings.preset.dialect != .mlx {
            return String(localized: "[\(agent.name) hat kein Modell gewählt.]")
        }

        let provider = settings.makeProvider(apiKey: apiKey)
        // Workers get the normal tools minus delegation (see above).
        let tools = await ToolRegistry.makeTools(settings: settings, apiKey: apiKey)
            .filter { $0.spec.name != AskAgentTool.toolName }

        var messages: [ChatMessage] = [
            ChatMessage(role: .system, text: systemPrompt(for: agent)),
            ChatMessage(role: .user, text: task),
        ]

        // `0...` gave one MORE round than the constant advertises, plus the
        // forced closing call after it.
        for _ in 0..<maxToolRounds {
            var text = ""
            var calls: [ToolCallData] = []
            do {
                for try await event in provider.streamChat(messages: messages, tools: tools.map(\.spec)) {
                    switch event {
                    case .textDelta(let piece): text += piece
                    case .toolCall(let call): calls.append(call)
                    case .done: break   // ends the switch; the stream ends itself
                    }
                    if Task.isCancelled { return "[\(agent.name): abgebrochen.]" }
                }
                if Task.isCancelled { return "[\(agent.name): abgebrochen.]" }
            } catch {
                return String(localized: "[\(agent.name) meldet einen Fehler: \(NetworkErrorFriendly.message(for: error))]")
            }

            guard !calls.isEmpty else {
                let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return answer.isEmpty
                    ? String(localized: "[\(agent.name) hat nichts zurückgegeben.]")
                    : String(answer.prefix(maxReplyCharacters))
            }

            messages.append(ChatMessage(role: .assistant, text: text, toolCalls: calls))
            for call in calls {
                // Cancellation between tool rounds was not honoured: a stopped
                // delegation kept running tools and spending the user's credits.
                if Task.isCancelled { return "[\(agent.name): abgebrochen.]" }
                let result: String
                if let tool = tools.first(where: { $0.spec.name == call.name }) {
                    result = await tool.run(argumentsJSON: call.argumentsJSON).text
                } else {
                    result = "Error: unbekanntes Tool \(call.name)"
                }
                messages.append(ChatMessage(
                    role: .tool,
                    text: result,
                    toolCallId: call.id,
                    toolName: call.name
                ))
            }
        }

        // Out of rounds: ask once more with no tools so it has to conclude.
        var closing = ""
        let finalStream = provider.streamChat(
            messages: messages + [ChatMessage(role: .user, text: "Fasse dein Ergebnis jetzt zusammen.")],
            tools: []
        )
        do {
            for try await event in finalStream {
                if case .textDelta(let piece) = event { closing += piece }
            }
        } catch {
            return "[\(agent.name) meldet einen Fehler: \(NetworkErrorFriendly.message(for: error))]"
        }
        let answer = closing.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty
            ? "[\(agent.name) kam zu keinem Ergebnis.]"
            : String(answer.prefix(maxReplyCharacters))
    }

    private static func systemPrompt(for agent: AgentDefinition) -> String {
        """
        Du bist „\(agent.name)“, ein spezialisierter Agent in der App aiity.

        Deine Aufgabe:
        \(agent.role)

        Regeln:
        - Du bekommst genau eine Aufgabe und lieferst genau eine Antwort. Es gibt keine Rückfragen — wenn etwas unklar ist, triff eine begründete Annahme und nenne sie.
        - Antworte kompakt und sachlich. Deine Antwort wird von einem anderen Agenten weiterverarbeitet, nicht direkt dem Nutzer gezeigt.
        - Keine Höflichkeitsfloskeln, keine Wiederholung der Aufgabe.
        - Wenn du etwas nicht sicher weißt und Web-Tools hast, recherchiere, bevor du antwortest.
        """
    }
}
