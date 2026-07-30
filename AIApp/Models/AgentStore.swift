import Foundation

/// One configured worker agent: a name, a role, and its own provider + model.
///
/// Agents are deliberately *not* separate chat surfaces. The chat you already
/// talk to is the lead; it hands work to these via the `ask_agent` tool and
/// folds their answers back into its own reply. That keeps one conversation to
/// read, bounds the cost (a worker runs once per delegation, not in a loop with
/// its peers), and means a worker can use a completely different provider than
/// the lead — a cheap local model for grunt work, a strong cloud model to review.
struct AgentDefinition: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// What this agent is for, in the user's words. Becomes its system prompt
    /// and is also what the lead sees when deciding whom to ask.
    var role: String
    var emoji: String = "🤖"
    /// Provider preset this agent runs on. Empty = follow the chat provider.
    var presetId: String = ""
    /// Model id for that provider. Empty = that provider's default.
    var model: String = ""
    var enabled: Bool = true

    /// Name normalised for tool arguments — the model will echo this back.
    var slug: String {
        let allowed = name.lowercased().map { char -> Character in
            char.isLetter || char.isNumber ? char : "-"
        }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }

    /// Resolved connection for this agent. Falls back to the chat provider so a
    /// freshly created agent works before anything is configured on it.
    func settings(fallback: ProviderSettings) -> ProviderSettings {
        guard !presetId.isEmpty else {
            var inherited = fallback
            if !model.isEmpty { inherited.model = model }
            return inherited
        }
        var resolved = ProviderSettings.connectionSnapshot(presetId: presetId)
        if !model.isEmpty { resolved.model = model }
        return resolved
    }

    /// Label for lists: which brain this agent actually runs on.
    func providerLabel(fallback: ProviderSettings) -> String {
        let resolved = settings(fallback: fallback)
        let modelName = resolved.effectiveModel
        let provider = ProviderPreset.preset(for: resolved.presetId).label
        if modelName.isEmpty { return provider }
        let short = modelName.count > 24 ? String(modelName.prefix(22)) + "…" : modelName
        return "\(provider) · \(short)"
    }
}

@MainActor
final class AgentStore: ObservableObject {
    /// One instance app-wide. Two views each holding their own store meant
    /// agents created in the Agenten tab never reached the chat list's copy —
    /// the group picker silently offered a stale roster.
    static let shared = AgentStore()

    @Published private(set) var agents: [AgentDefinition] = []

    private static let fileName = "agents.json"

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    init() {
        agents = Self.load()
    }

    /// Re-read from disk. Cheap, and the only thing that keeps a long-lived
    /// view honest if the file changes underneath it (import, restore).
    func reload() {
        agents = Self.load()
    }

    static func load() -> [AgentDefinition] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AgentDefinition].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Enabled agents only — what the lead is actually allowed to delegate to.
    static func active() -> [AgentDefinition] {
        load().filter { $0.enabled && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func add(_ agent: AgentDefinition) {
        agents.append(agent)
        persist()
    }

    func update(_ agent: AgentDefinition) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[index] = agent
        persist()
    }

    func delete(_ agent: AgentDefinition) {
        agents.removeAll { $0.id == agent.id }
        persist()
    }

    func toggle(_ agent: AgentDefinition) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[index].enabled.toggle()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(agents) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
