import Foundation

/// Writes or sharpens an agent's role description with the chat model.
///
/// An agent's role becomes its system prompt *and* is what the lead reads when
/// deciding whom to ask, so a vague one line ("hilft mit Code") makes the agent
/// worse at its job and harder to route work to. Getting a good one out of a
/// blank field is exactly the kind of writing a model is good at.
enum AgentRoleWriter {
    /// Roles are prompts, not essays — a wall of text crowds the conversation
    /// out of the context window.
    static let maxCharacters = 700

    enum WriterError: LocalizedError {
        case notConfigured
        case empty

        var errorDescription: String? {
            switch self {
            case .notConfigured: return String(localized: "Kein Chat-Modell verbunden — unter Anbieter einrichten.")
            case .empty: return String(localized: "Das Modell hat nichts zurückgegeben.")
            }
        }
    }

    /// Draft a role from just a name, or improve one the user has started.
    /// Passing existing text switches from writing to editing — the user's
    /// intent is kept and tightened rather than replaced with something new.
    static func write(name: String, existing: String, settings: ProviderSettings) async throws -> String {
        let apiKey = await AuthStore.effectiveKey(for: settings)
        if settings.preset.needsKey, apiKey.isEmpty, !ConnectionProbe.isSelfHostedEndpoint(settings.presetId) {
            throw WriterError.notConfigured
        }
        let provider = settings.makeProvider(apiKey: apiKey)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = existing.trimmingCharacters(in: .whitespacesAndNewlines)

        let task = draft.isEmpty
            ? "Schreibe die Aufgabenbeschreibung für einen Agenten namens „\(trimmedName.isEmpty ? "Assistent" : trimmedName)“."
            : """
              Verbessere diese Aufgabenbeschreibung für den Agenten \
              „\(trimmedName.isEmpty ? "Assistent" : trimmedName)“. Behalte die Absicht \
              des Nutzers bei — mach sie schärfer, nicht anders:

              \(draft)
              """

        var text = ""
        let stream = provider.streamChat(
            messages: [
                ChatMessage(role: .system, text: systemPrompt),
                ChatMessage(role: .user, text: task),
            ],
            tools: []
        )
        for try await event in stream {
            if case .textDelta(let piece) = event { text += piece }
        }

        let result = clean(text)
        guard !result.isEmpty else { throw WriterError.empty }
        return String(result.prefix(maxCharacters))
    }

    private static let systemPrompt = """
    Du formulierst Aufgabenbeschreibungen für KI-Agenten. Die Beschreibung wird \
    wortwörtlich zum System-Prompt des Agenten und entscheidet, wann ihm Arbeit \
    zugewiesen wird.

    Regeln:
    - Antworte NUR mit der Beschreibung. Keine Anrede, keine Erklärung, keine \
    Anführungszeichen, keine Überschrift, keine Aufzählungszeichen.
    - Zwei bis vier Sätze, höchstens 500 Zeichen.
    - Schreib, WAS der Agent tut und WIE er antwortet — konkret und prüfbar, \
    nicht „hilft bei allem“.
    - Nenne, wo sinnvoll, was er ausdrücklich NICHT tut.
    - Zweite Person Singular oder neutrale Beschreibung, deutsch.
    """

    /// Models like to wrap prose in quotes or a fence despite being told not to.
    private static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: #"^```[a-zA-Z]*\n?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\n?```$"#, with: "", options: .regularExpression)
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”„‟ \n"))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
