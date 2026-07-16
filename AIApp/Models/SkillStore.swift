import Foundation

/// An installable instruction pack for the agent. Enabled skills are
/// appended to the system prompt — they specialize how mini-apps get built
/// (design systems, games, charts, domain knowledge) without code changes.
struct AgentSkill: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var summary: String
    var instructions: String
    var enabled: Bool
    var builtin = false
}

@MainActor
final class SkillStore: ObservableObject {
    @Published private(set) var skills: [AgentSkill] = []
    @Published var errorMessage: String?

    private static let fileURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("skills.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let stored = try? JSONDecoder().decode([AgentSkill].self, from: data) {
            skills = stored
        } else {
            skills = Self.builtins
            persist()
        }
    }

    /// Read by the agent loop at send time — file-based so no view wiring is
    /// needed and changes apply to the next message immediately.
    static func enabledInstructions() -> String {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([AgentSkill].self, from: data) else { return "" }
        return stored.filter(\.enabled)
            .map { "## Skill: \($0.name)\n\($0.instructions)" }
            .joined(separator: "\n\n")
    }

    func toggle(_ skill: AgentSkill) {
        update(skill) { $0.enabled.toggle() }
    }

    func remove(_ skill: AgentSkill) {
        skills.removeAll { $0.id == skill.id }
        persist()
    }

    func add(name: String, instructions: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedInstructions.isEmpty else { return }
        skills.append(AgentSkill(
            name: trimmedName,
            summary: String(trimmedInstructions.prefix(80)),
            instructions: trimmedInstructions,
            enabled: true
        ))
        persist()
    }

    /// Install a skill from a URL pointing at a plain-text/markdown file.
    func install(from urlString: String) async {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme ?? "") else {
            errorMessage = "Ungültige URL."
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let text = String(decoding: data.prefix(60_000), as: UTF8.self)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "Datei ist leer."
                return
            }
            let name = Self.title(of: text) ?? url.deletingPathExtension().lastPathComponent
            add(name: name, instructions: text)
            errorMessage = nil
        } catch {
            errorMessage = "Download fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private static func title(of markdown: String) -> String? {
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            }
        }
        return nil
    }

    private func update(_ skill: AgentSkill, _ mutate: (inout AgentSkill) -> Void) {
        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        mutate(&skills[index])
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(skills) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    static let builtins: [AgentSkill] = [
        AgentSkill(
            name: "UI-Design Pro",
            summary: "Konsistentes Design-System für alle Mini-Apps",
            instructions: """
            Apply this design system to every mini-app:
            - Define CSS custom properties in :root for colors, spacing and radii; override them in @media (prefers-color-scheme: dark). Never hardcode colors inline.
            - Typography: -apple-system font stack; a clear scale (title 28px/700, section 17px/600, body 15px/400, caption 13px muted).
            - Layout: max-width 640px centered, 16px outer padding, cards with 16px radius and soft shadow (0 1px 3px rgba(0,0,0,.12)), 12px gaps.
            - Controls: minimum 44px touch targets, 12px radius buttons with a pressed state (transform: scale(.97)), inputs with visible focus ring.
            - Motion: 150-250ms ease transitions for state changes; animate list insertions/removals subtly.
            - Always design empty states (icon + one friendly sentence + primary action).
            """,
            enabled: true,
            builtin: true
        ),
        AgentSkill(
            name: "Spiele-Entwickler",
            summary: "Canvas-Games mit Touch-Steuerung",
            instructions: """
            When building games:
            - Use a <canvas> sized to devicePixelRatio with a requestAnimationFrame loop and delta-time based movement (never setInterval).
            - Touch controls: large invisible touch zones or drag steering; prevent default scrolling on the canvas; support both touch and pointer events.
            - Structure: game states (start screen, running, game over) with restart; score display; increasing difficulty.
            - Persist the high score via miniapp.storage and show it on the start screen. Trigger miniapp.haptic() on hits and game over.
            - Keep 60fps: no allocations in the loop, simple shapes/gradients instead of images.
            """,
            enabled: false,
            builtin: true
        ),
        AgentSkill(
            name: "Diagramme & Charts",
            summary: "Datenvisualisierung als Inline-SVG",
            instructions: """
            When data needs visualization:
            - Draw charts as inline SVG (no libraries): axes with tick labels, gridlines at 10% opacity, animated path/bar entrance via CSS.
            - Bars/lines use one accent color plus muted grays; label values directly at the data points when few, tooltip-on-tap when many.
            - Make the SVG responsive (viewBox + width:100%) and readable in dark mode (currentColor for axes/text).
            - Format numbers compactly (1.2k, 3,4 Mio) and localize German decimal commas.
            """,
            enabled: false,
            builtin: true
        ),
    ]
}
