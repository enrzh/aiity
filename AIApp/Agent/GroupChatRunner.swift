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
    /// Cap for ordinary discussion turns, so one verbose agent cannot crowd out
    /// the rest of the transcript.
    static let maxReplyCharacters = 4_000
    /// A turn that contains code is not a discussion turn. 4k slices a mini-app
    /// mid-function — the user saw exactly that three times, and the agents
    /// correctly blamed "Nachrichtenlänge", not the code.
    static let maxCodeReplyCharacters = 60_000

    /// Truncation budget for one turn: generous when the agent is delivering an
    /// artifact, tight when it is talking.
    static func replyLimit(for text: String) -> Int {
        text.contains("```") ? maxCodeReplyCharacters : maxReplyCharacters
    }
    /// Messages of shared history each speaker receives. Bounds the cost of a
    /// long-running group, which otherwise grows with every turn for everyone.
    static let maxTranscriptMessages = 40

    /// Memory warnings during a round on an on-device model are routine — the
    /// runtime releases the model and carries on. A verified healthy
    /// three-agent round produced six. This threshold is a runaway backstop,
    /// deliberately well above that: below it, stopping would break the
    /// feature more reliably than the crash it is meant to prevent.
    static let memoryWarningAbortThreshold = 16

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
        let speaking = Array(speakingOrder(agents).prefix(maxAgentsPerRound))
        if agents.count > speaking.count {
            // Silently muting members looks like a broken app; say it once.
            onTurn(Turn(
                agent: AgentDefinition(name: "aiity", role: "", emoji: "ℹ️"),
                text: "Diese Runde spricht nur mit den ersten \(maxAgentsPerRound) Agenten der Gruppe."
            ))
        }
        for agent in speaking {
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

            let trimmed = String(text.prefix(replyLimit(for: text)))
            onTurn(Turn(agent: agent, text: trimmed))
            // The next speaker must see this one, attributed — otherwise every
            // agent answers the user in isolation and nobody is talking to
            // anybody.
            running.append(ChatMessage(
                role: .assistant,
                text: trimmed,
                authorName: agent.name,
                authorEmoji: agent.emoji
            ))
        }
    }

    /// Contributors first in the user's chosen order, the lead last — it can
    /// only decide on what it has actually heard.
    static func speakingOrder(_ agents: [AgentDefinition]) -> [AgentDefinition] {
        agents.filter { !$0.isLead } + agents.filter(\.isLead)
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
        // MLX used to be exempt here, on the assumption it had a sensible
        // default. It does not — the preset's defaultModel is "" — so an agent
        // with no model chosen went on to load nothing and the round failed
        // deep inside the runtime instead of here. That configuration was
        // live on a real device.
        if settings.effectiveModel.trimmingCharacters(in: .whitespaces).isEmpty {
            return settings.preset.dialect == .mlx
                ? "(kein lokales Modell gewählt — unter Anbieter eins laden und auswählen)"
                : "(kein Modell gewählt)"
        }

        let provider = settings.makeProvider(apiKey: apiKey)
        var messages: [ChatMessage] = [
            ChatMessage(role: .system, text: systemPrompt(for: agent, peers: peers)),
        ]
        // Only the recent window: every agent re-reads the transcript each
        // turn, so an untrimmed history costs agents × rounds × full history.
        // On-device models get a much smaller one — there the history is not
        // just tokens billed, it is resident memory the process may not have.
        messages += perspective(
            of: agent,
            transcript: LocalRuntimePolicy.transcriptWindow(
                transcript, for: settings, cloudLimit: maxTranscriptMessages
            )
        )

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

    /// Rewrite the shared transcript from one agent's point of view.
    ///
    /// This is the difference between a discussion and several monologues. A
    /// chat model treats every `.assistant` message as something IT said, so
    /// handing an agent its peers' turns in the assistant role makes them read
    /// as its own train of thought — and nobody argues with themselves. Only
    /// this agent's own turns stay `.assistant`; everyone else's arrive as
    /// `.user`, named, which is what makes them something to respond to.
    static func perspective(of agent: AgentDefinition, transcript: [ChatMessage]) -> [ChatMessage] {
        transcript.compactMap { message in
            switch message.role {
            case .user:
                return ChatMessage(role: .user, text: message.text)
            case .assistant:
                guard let author = message.authorName else {
                    // The plain assistant (a non-group turn in this thread).
                    return ChatMessage(role: .user, text: message.text)
                }
                // Compared against the agent's OWN name; two agents sharing a
                // name genuinely are indistinguishable here, which is why the
                // editor now refuses duplicates rather than pretending to cope.
                if author == agent.name {
                    return ChatMessage(role: .assistant, text: message.text)
                }
                return ChatMessage(role: .user, text: "\(author): \(message.text)")
            case .system, .tool:
                // A peer's tool plumbing is not part of the conversation.
                return nil
            }
        }
    }

    /// What the lead is for. Without this a group produces N opinions and
    /// no outcome — the complaint that agents talk away from each other.
    private static let leadBrief = """
        DU LEITEST DIESE GRUPPE. Du sprichst als Letzter, nachdem alle anderen dran waren.
        Deine Aufgabe ist nicht, noch eine Meinung hinzuzufügen, sondern daraus ETWAS ZU MACHEN:
        - Fass zusammen, worauf ihr euch einig seid, und entscheide, wo ihr es nicht seid — mit Begründung.
        - Sag verbindlich, was als Nächstes passiert und wer was beiträgt.
        - Wenn die Runde reif dafür ist, liefere das eigentliche Ergebnis direkt (Plan, Entwurf, Text).
        - Fehlt noch etwas Wesentliches, benenne genau diese eine Lücke statt allgemein weiterzureden.
        - Wenn eine Mini-App gefragt ist, liefere sie SELBST und VOLLSTÄNDIG in EINEM ```html-Block
          (CSS und JS inline, kein Abbruch, keine Fortsetzung in einer zweiten Nachricht).
        """

    private static let contributorBrief = """
        In dieser Gruppe entscheidet am Ende die Leitung und führt die Beiträge zusammen.
        Liefere deinen Fachbeitrag aus deiner Rolle heraus — knapp und konkret, damit die Leitung damit arbeiten kann.
        Wiederhol nicht die Aufgabe und fass nicht die anderen zusammen; das macht die Leitung.
        """

    private static func systemPrompt(for agent: AgentDefinition, peers: [AgentDefinition]) -> String {
        let others = peers
            .filter { $0.id != agent.id }
            .map { "\($0.emoji) \($0.name)\($0.isLead ? " (Leitung)" : "") — \($0.role.prefix(120))" }
            .joined(separator: "\n")
        let roster = others.isEmpty
            ? "Du bist der einzige Agent in dieser Runde."
            : "Ebenfalls in der Gruppe:\n\(others)"

        return """
        Du bist „\(agent.name)“ in einem Gruppenchat mit dem Nutzer und anderen Agenten.

        Deine Rolle:
        \(agent.role)

        \(roster)

        \(agent.isLead ? leadBrief : contributorBrief)

        So läuft der Chat:
        - Antworte NUR als \(agent.name), in der Ich-Form. Schreib niemals die Beiträge der anderen.
        - Stell deinen Namen NICHT voran — das macht die App.
        - Beiträge der anderen erscheinen als Nachrichten mit „Name: …“ davor. Das sind ANDERE Personen, nicht du. Geh direkt auf sie ein — sprich sie beim Namen an, stimm zu, widersprich begründet, ergänze. Wiederhol nichts, was schon gesagt wurde.
        - Wenn schon jemand vor dir geantwortet hat, beginne mit einem echten Bezug auf das Gesagte, nicht mit einer eigenen Einleitung.
        - Halt dich kurz: ein bis fünf Sätze, so wie man in einem Chat schreibt.
        - Wenn du nichts Substanzielles beizutragen hast, sag das in einem Satz statt zu füllen.
        - Antworte in der Sprache des Nutzers.
        """
    }
}
