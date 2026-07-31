#if DEBUG
import Foundation

/// Headless check that a group round produces a real, converging conversation
/// on the user's own configured provider.
///
/// Launch with `AIITY_GROUP_SELFTEST=<question>` and watch the console. The UI
/// cannot be driven on a physical device from here, and the test stub returns
/// nothing, so this is the only way to see what real models actually say to
/// each other — which is the thing being claimed when we say the lead makes
/// them converge.
enum GroupSelfTest {
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let question = environment["AIITY_GROUP_SELFTEST"], !question.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            await run(question: question)
        }
    }

    private static func run(question: String) async {
        let settings = await MainActor.run { ProviderSettings.load() }
        print("AIITY-GROUP START provider=\(settings.presetId) model=\(settings.effectiveModel)")
        print("AIITY-GROUP FRAGE \(question)")

        // Two specialists and a lead — the shape the feature is meant for.
        let agents = [
            AgentDefinition(
                name: "Rechercheur", role: "Nennt die harten Fakten und Zahlen, die für die Entscheidung zählen. Sagt klar, was unsicher ist.",
                emoji: "🔎"
            ),
            AgentDefinition(
                name: "Kritiker", role: "Sucht die Schwachstelle im Vorschlag: falsche Annahme, fehlender Fall, unbegründete Behauptung.",
                emoji: "🧐"
            ),
            AgentDefinition(
                name: "Leitung", role: "Führt die Beiträge zu einer Entscheidung zusammen und benennt den nächsten Schritt.",
                emoji: "⭐️", isLead: true
            ),
        ]

        let order = GroupChatRunner.speakingOrder(agents).map(\.name)
        print("AIITY-GROUP REIHENFOLGE \(order.joined(separator: " → "))")

        let started = Date()
        await GroupChatRunner.runRound(
            agents: agents,
            transcript: [ChatMessage(role: .user, text: question)],
            chatSettings: settings,
            isCancelled: { false },
            onStart: { agent in print("AIITY-GROUP … \(agent.name) denkt nach") },
            onTurn: { turn in
                let text = turn.text.replacingOccurrences(of: "\n", with: " ⏎ ")
                print("AIITY-GROUP [\(turn.agent.name)] \(text)")
            }
        )
        print(String(format: "AIITY-GROUP FERTIG in %.1fs", Date().timeIntervalSince(started)))
    }
}
#endif
