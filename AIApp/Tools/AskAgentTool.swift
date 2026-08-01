import Foundation

/// Lets the lead chat hand a task to one of the user's configured agents.
///
/// This is the whole orchestration surface: the lead decides *whom* to ask and
/// *what* to ask, the worker answers once, and the lead folds that answer into
/// its own reply. Workers never receive this tool, so delegation is one level
/// deep by construction.
struct AskAgentTool: AgentTool {
    static let toolName = "ask_agent"

    /// Agents available at the time the turn started.
    var agents: [AgentDefinition]
    /// Chat provider, used as the fallback brain for agents with none of their own.
    var chatSettings: ProviderSettings

    var spec: ToolSpec {
        let roster = agents
            .map { "\"\($0.slug)\" — \($0.name): \($0.role.prefix(160))" }
            .joined(separator: "\n")
        return ToolSpec(
            name: Self.toolName,
            description: """
            Delegate a self-contained task to one of the user's specialised agents \
            and get its answer back. Use it when a task matches an agent's speciality \
            better than your own, or when you want a second opinion from a different \
            model. Ask one agent at a time and give it everything it needs — it cannot \
            see this conversation. Available agents:
            \(roster)
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "agent": [
                        "type": "string",
                        "description": "Agent id to ask",
                        "enum": agents.map(\.slug),
                    ],
                    "task": [
                        "type": "string",
                        "description": "The complete, self-contained task. Include all context the agent needs — it cannot see the chat.",
                    ],
                ],
                "required": ["agent", "task"],
            ]
        )
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        let arguments = toolArguments(argumentsJSON)
        let requested = (arguments["agent"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let task = (arguments["task"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !task.isEmpty else {
            return ToolRunResult(String(localized: "Error: leere Aufgabe — beschreibe, was der Agent tun soll."))
        }
        // Match on slug first, then on name, so a model that echoes the display
        // name instead of the id still routes correctly.
        let lowered = requested.lowercased()
        guard let agent = agents.first(where: { $0.slug == lowered })
            ?? agents.first(where: { $0.name.lowercased() == lowered }) else {
            let known = agents.map(\.slug).joined(separator: ", ")
            return ToolRunResult(String(localized: "Error: kein Agent „\(requested)“. Verfügbar: \(known)"))
        }

        let answer = await SubAgentRunner.run(
            agent: agent,
            task: task,
            chatSettings: chatSettings
        )
        return ToolRunResult("Antwort von \(agent.name):\n\(answer)")
    }
}
