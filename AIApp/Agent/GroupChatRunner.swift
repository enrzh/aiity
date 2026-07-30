import Foundation

/// Runs one round of a group conversation: every participating agent speaks
/// once, in order, each seeing everything said before it — including what its
/// peers just said in the same round. That is what makes it a discussion
/// rather than several parallel monologues.
///
/// Rounds are explicit and finite. There is no self-continuing loop: the user
/// asks, the group answers once, and continuing costs another deliberate tap.
/// Autonomous agent-to-agent chatter has no natural stopping point, and it
/// spends the user's own API credits while it drifts.
enum GroupChatRunner {
    /// Speaking turns per round, per agent. Keeps one round bounded even if the
    /// user has configured many agents.
    static let maxAgentsPerRound = 6
    /// A single contribution is capped so one verbose agent can't crowd out the
    /// rest of the transcript.
    static let maxReplyCharacters = 4_000

    struct Turn {
        var agent: AgentDefinition
        var text: String
    }

    /// Ask each agent in turn. `onTurn` is called as each one finishes so the
    /// UI can append it live rather than after the whole round.
    static func runRound(
        agents: [AgentDefinition],
        transcript: [ChatMessage],
        chatSettings: ProviderSettings,
        isCancelled: @escaping () -> Bool,
        onStart: @escaping (AgentDefinition) -> Void,
        onTurn: @escaping (Turn) -> Void
    ) async {
        var running = transcript
        for agent in agents.prefix(maxAgentsPerRound) {
            if isCancelled() { return }
            onStart(agent)

            let settings = agent.settings(fallback: chatSettings)
            let apiKey = await AuthStore.effectiveKey(for: settings)
            let text = await speak(
                agent: agent,
                peers: agents,
                transcript: running,
                settings: settings,
                apiKey: apiKey,
                isCancelled: isCancelled
            )
            if isCancelled() { return }

            let trimmed = String(text.prefix(maxReplyCharacters))
            onTurn(Turn(agent: agent, text: trimmed))
            // The next speaker must see this one, attributed — otherwise every
            // agent answers the user in isolation and nobody is talking to
            // anybody.
            running.append(ChatMessage(
                role: .assistant,
                text: "\(agent.name): \(trimmed)",
                authorName: agent.name,
                authorEmoji: agent.emoji
            ))
        }
    }

    private static func speak(
        agent: AgentDefinition,
        peers: [AgentDefinition],
        transcript: [ChatMessage],
        settings: ProviderSettings,
        apiKey: String,
        isCancelled: @escaping () -> Bool
    ) async -> String {
        if settings.preset.needsKey, apiKey.isEmpty, !ConnectionProbe.isLocalStyle(settings.presetId) {
            return "(kein Konto hinterlegt — unter Anbieter einen Key eintragen)"
        }
        if settings.effectiveModel.trimmingCharacters(in: .whitespaces).isEmpty,
           settings.preset.dialect != .mlx {
            return "(kein Modell gewählt)"
        }

        let provider = settings.makeProvider(apiKey: apiKey)
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, text: systemPrompt(for: agent, peers: peers)),
        ]
        // Drop system/tool noise from the shared history — a peer's tool
        // plumbing is not part of the conversation.
        messages += transcript.filter { $0.role == .user || $0.role == .assistant }

        var text = ""
        do {
            // No tools in a group round: a discussion turn should be the agent
            // thinking out loud, not a silent multi-minute tool loop with the
            // other participants waiting.
            for try await event in provider.streamChat(messages: messages, tools: []) {
                if case .textDelta(let piece) = event { text += piece }
                if isCancelled() { break }
            }
        } catch {
            return "(Fehler: \(NetworkErrorFriendly.message(for: error)))"
        }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? "(keine Antwort)" : answer
    }

    private static func systemPrompt(for agent: AgentDefinition, peers: [AgentDefinition]) -> String {
        let others = peers
            .filter { $0.id != agent.id }
            .map { "\($0.emoji) \($0.name) — \($0.role.prefix(120))" }
            .joined(separator: "\n")
        let roster = others.isEmpty
            ? "Du bist der einzige Agent in dieser Runde."
            : "Ebenfalls in der Gruppe:\n\(others)"

        return """
        Du bist „\(agent.name)“ in einem Gruppenchat mit dem Nutzer und anderen Agenten.

        Deine Rolle:
        \(agent.role)

        \(roster)

        So läuft der Chat:
        - Antworte NUR als \(agent.name), in der Ich-Form. Schreib niemals die Beiträge der anderen.
        - Stell deinen Namen NICHT voran — das macht die App.
        - Beiträge der anderen stehen im Verlauf mit „Name: …“. Geh direkt darauf ein: stimm zu, widersprich, ergänze. Wiederhol nicht, was schon gesagt wurde.
        - Halt dich kurz: ein bis fünf Sätze, so wie man in einem Chat schreibt.
        - Wenn du nichts Substanzielles beizutragen hast, sag das in einem Satz statt zu füllen.
        - Antworte in der Sprache des Nutzers.
        """
    }
}
