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
    /// Leads the group: speaks LAST, after hearing everyone, and is expected to
    /// decide and produce the actual output rather than add another opinion.
    /// Without one, every agent answers the user in parallel and nobody owns
    /// the result — which reads as agents talking past each other.
    var isLead: Bool = false

    init(
        id: UUID = UUID(),
        name: String,
        role: String,
        emoji: String = "🤖",
        presetId: String = "",
        model: String = "",
        enabled: Bool = true,
        isLead: Bool = false
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.emoji = emoji
        self.presetId = presetId
        self.model = model
        self.enabled = enabled
        self.isLead = isLead
    }

    // Hand-written for the same reason as `ChatThread`: Swift's synthesized
    // decoder treats a DEFAULTED property as required, so the next field added
    // here would make every stored agent undecodable — and one throw fails the
    // whole array, wiping the roster. Only name and role are truly mandatory.
    private enum CodingKeys: String, CodingKey {
        case id, name, role, emoji, presetId, model, enabled, isLead
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "🤖"
        presetId = try c.decodeIfPresent(String.self, forKey: .presetId) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        isLead = try c.decodeIfPresent(Bool.self, forKey: .isLead) ?? false
    }

    /// Name normalised for tool arguments — the model will echo this back.
    var slug: String {
        let allowed = name.lowercased().map { char -> Character in
            char.isLetter || char.isNumber ? char : "-"
        }
        let slug = String(allowed).split(separator: "-").joined(separator: "-")
        // A name of only punctuation/emoji would slug to "", collapsing every
        // such agent onto one delegation target. Fall back to the id.
        return slug.isEmpty ? "agent-\(id.uuidString.prefix(8).lowercased())" : slug
    }

    /// Resolved connection for this agent. Falls back to the chat provider so a
    /// freshly created agent works before anything is configured on it.
    func settings(fallback: ProviderSettings) -> ProviderSettings {
        guard !presetId.isEmpty else {
            var inherited = fallback
            inherited.applyAgentModel(model)
            return inherited
        }
        var resolved = ProviderSettings.connectionSnapshot(presetId: presetId)
        resolved.applyAgentModel(model)
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

/// Starting points offered when the user has no agents yet.
///
/// Roles only — the model is deliberately NOT preset. Which brain an agent runs
/// on is a cost and privacy decision that belongs to the user; a suggestion
/// that silently picks an expensive model is a suggestion that spends their
/// money. Each carries a hint instead.
enum AgentSuggestion {
    struct Template: Identifiable {
        var id: String { name }
        let name: String
        let emoji: String
        let role: String
        /// What kind of model suits this job, in plain terms.
        let modelHint: String
    }

    static let all: [Template] = [
        Template(
            name: "Rechercheur",
            emoji: "🔎",
            role: "Recherchiert Fakten im Web, prüft sie an mehreren Quellen und fasst sie mit Quellenangabe zusammen. Sagt ausdrücklich, wenn etwas unsicher oder widersprüchlich ist.",
            modelHint: "Ein starkes Cloud-Modell — Recherche lebt von Sorgfalt."
        ),
        Template(
            name: "Kritiker",
            emoji: "🧐",
            role: "Sucht gezielt Schwachstellen in Plänen und Texten: falsche Annahmen, fehlende Fälle, unbegründete Behauptungen. Formuliert knapp und konkret, ohne Höflichkeitsfloskeln.",
            modelHint: "Ein starkes Modell — Kritik ist wertlos, wenn sie oberflächlich ist."
        ),
        Template(
            name: "Planer",
            emoji: "🗺️",
            role: "Zerlegt ein Ziel in eine überschaubare Reihenfolge konkreter Schritte, benennt Abhängigkeiten und sagt, was zuerst geklärt werden muss.",
            modelHint: "Mittelklasse reicht meist."
        ),
        Template(
            name: "Übersetzer",
            emoji: "🌍",
            role: "Übersetzt Texte natürlich statt wörtlich, behält Ton und Fachbegriffe bei und markiert Stellen, die im Original mehrdeutig sind.",
            modelHint: "Auch ein günstiges Modell macht das gut."
        ),
        Template(
            name: "Zusammenfasser",
            emoji: "📝",
            role: "Fasst lange Texte auf das Wesentliche zusammen: Kernaussage zuerst, dann die Punkte, die eine Entscheidung verändern würden. Keine Füllsätze.",
            modelHint: "Ein günstiges, schnelles Modell genügt."
        ),
    ]

    /// A template as a fresh agent — provider intentionally left empty, so it
    /// inherits the chat provider until the user chooses one.
    static func agent(from template: Template) -> AgentDefinition {
        AgentDefinition(name: template.name, role: template.role, emoji: template.emoji)
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
        #if DEBUG
        // Hermetic UI tests: agents.json otherwise persists in the simulator
        // container between runs, so each run inherited every agent an earlier
        // one created — eleven of them, several sharing a name. That polluted
        // the roster the test selects from and made failures meaningless.
        if let override = ProcessInfo.processInfo.environment["AIITY_AGENTS_FILE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
