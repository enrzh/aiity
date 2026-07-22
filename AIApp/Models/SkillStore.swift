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
    /// Optional package version from SKILL.md frontmatter.
    var packageVersion: String?
    /// Origin for updates (GitHub-style spec, bundled:name, or URL).
    var source: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, instructions, enabled, builtin, packageVersion, source
    }

    init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        instructions: String,
        enabled: Bool,
        builtin: Bool = false,
        packageVersion: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.enabled = enabled
        self.builtin = builtin
        self.packageVersion = packageVersion
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decode(String.self, forKey: .summary)
        instructions = try c.decode(String.self, forKey: .instructions)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        packageVersion = try c.decodeIfPresent(String.self, forKey: .packageVersion)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    var isImported: Bool { !builtin }
}

@MainActor
final class SkillStore: ObservableObject {
    @Published private(set) var skills: [AgentSkill] = []
    @Published var errorMessage: String?
    @Published var lastInstallMessage: String?

    nonisolated private static let fileURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("skills.json")
    }()

    nonisolated(unsafe) static var fileURLOverride: URL?

    nonisolated private static var resolvedFileURL: URL { fileURLOverride ?? fileURL }

    init() {
        if let data = try? Data(contentsOf: Self.resolvedFileURL),
           let stored = try? JSONDecoder().decode([AgentSkill].self, from: data) {
            skills = stored
            // Ensure builtins always exist (migrate old installs missing them).
            for b in Self.builtins where !skills.contains(where: { $0.builtin && $0.name == b.name }) {
                skills.append(b)
            }
            persist()
        } else {
            skills = Self.builtins
            persist()
        }
    }

    nonisolated static func enabledInstructions(maxChars: Int = 12_000) -> String {
        SkillPackage.promptInjectionPreferringImports(from: loadFromDisk(), maxChars: maxChars)
    }

    nonisolated static func enabledRoster() -> String {
        SkillPackage.enabledRoster(from: loadFromDisk())
    }

    nonisolated static func enabledCount() -> Int {
        loadFromDisk().filter(\.enabled).count
    }

    nonisolated static func enabledImportedCount() -> Int {
        loadFromDisk().filter { $0.enabled && !$0.builtin }.count
    }

    nonisolated private static func loadFromDisk() -> [AgentSkill] {
        guard let data = try? Data(contentsOf: resolvedFileURL),
              let stored = try? JSONDecoder().decode([AgentSkill].self, from: data) else {
            return builtins
        }
        return stored
    }

    nonisolated static func promptInjection(from skills: [AgentSkill], maxChars: Int = 12_000) -> String {
        SkillPackage.promptInjection(from: skills, maxChars: maxChars)
    }

    func toggle(_ skill: AgentSkill) {
        update(skill) { $0.enabled.toggle() }
    }

    func remove(_ skill: AgentSkill) {
        guard !skill.builtin else { return }
        skills.removeAll { $0.id == skill.id }
        persist()
    }

    func add(name: String, instructions: String, summary: String? = nil, source: String? = nil, version: String? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedInstructions.isEmpty else { return }
        skills.removeAll { !$0.builtin && $0.name == trimmedName }
        let skill = AgentSkill(
            name: trimmedName,
            summary: summary ?? String(trimmedInstructions.prefix(80)),
            instructions: trimmedInstructions,
            enabled: true,
            packageVersion: version,
            source: source
        )
        if let firstBuiltin = skills.firstIndex(where: \.builtin) {
            skills.insert(skill, at: firstBuiltin)
        } else {
            skills.insert(skill, at: 0)
        }
        persist()
    }

    @discardableResult
    func installPackage(markdown: String, source: String? = nil) -> AgentSkill? {
        let customCount = skills.filter { !$0.builtin }.count
        if let doc = SkillPackage.parse(markdown: markdown, source: source),
           !skills.contains(where: { !$0.builtin && $0.name == doc.name }),
           !FreeTier.canInstallSkill(currentCustomCount: customCount) {
            errorMessage = FreeTier.skillLimitMessage
            return nil
        }
        guard let doc = SkillPackage.parse(markdown: markdown, source: source) else {
            errorMessage = "Kein gültiges Skill-Paket (SKILL.md leer oder unlesbar)."
            return nil
        }
        add(
            name: doc.name,
            instructions: doc.instructions,
            summary: doc.summary,
            source: source ?? doc.source,
            version: doc.version
        )
        errorMessage = nil
        lastInstallMessage = "„\(doc.name)“ installiert und aktiv."
        // add() inserts before builtins — find by name
        return skills.first { !$0.builtin && $0.name == doc.name }
    }

    func installFromZipData(_ data: Data, source: String?) throws {
        let markdown = try ZipSkillExtractor.skillMarkdown(from: data)
        if installPackage(markdown: markdown, source: source) == nil, errorMessage != nil {
            throw NSError(domain: "SkillStore", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "Install failed"])
        }
    }

    /// Install from `bundled:name`, GitHub-style spec, or URL.
    func install(from urlString: String) async {
        errorMessage = nil
        lastInstallMessage = nil
        let spec = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else {
            errorMessage = "Leere Quelle."
            return
        }

        // 1) Bundled package (always works offline)
        if spec.hasPrefix("bundled:") || BundledSkills.markdown(named: spec) != nil {
            let key = spec.hasPrefix("bundled:") ? spec : "bundled:\(spec)"
            if let md = BundledSkills.markdown(named: key) {
                _ = installPackage(markdown: md, source: key)
                return
            }
            errorMessage = "Gebündelter Skill „\(spec)“ nicht im App-Bundle."
            return
        }

        // 2) Network install with path variants
        let candidates = SkillPackage.candidateInstallURLs(spec)
        guard !candidates.isEmpty else {
            errorMessage = "Format: owner/repo/pfad@branch oder https://…"
            return
        }

        var lastError = "Nicht gefunden."
        for url in candidates {
            do {
                var request = URLRequest(url: url)
                request.setValue("aiity-ios", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 25
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 { lastError = "404: \(url.absoluteString)"; continue }
                if !(200...299).contains(code) && code != 0 {
                    lastError = "HTTP \(code): \(url.absoluteString)"
                    continue
                }
                let text = String(decoding: data.prefix(200_000), as: UTF8.self)
                let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lower.hasPrefix("<!doctype") || lower.contains("<html") {
                    lastError = "HTML statt Markdown: \(url.absoluteString)"
                    continue
                }
                if text.count < 40 {
                    lastError = "Datei zu kurz: \(url.absoluteString)"
                    continue
                }
                if installPackage(markdown: text, source: spec) != nil {
                    return
                }
                // parse failed
                lastError = errorMessage ?? "Parse fehlgeschlagen"
            } catch {
                lastError = error.localizedDescription
            }
        }

        // 3) Fallback: if spec matches a bundled name, install that
        let basename = spec.split(separator: "/").last.map(String.init)?
            .split(separator: "@").first.map(String.init) ?? spec
        if let md = BundledSkills.markdown(named: basename) {
            _ = installPackage(markdown: md, source: "bundled:\(basename)")
            lastInstallMessage = (lastInstallMessage ?? "") + " (Offline-Kopie, Remote war: \(lastError))"
            return
        }

        errorMessage = lastError
    }

    func updateFromSource(_ skill: AgentSkill) async {
        guard let source = skill.source, !source.isEmpty else {
            errorMessage = "Kein Remote-Source für Update."
            return
        }
        await install(from: source)
    }

    private func update(_ skill: AgentSkill, _ mutate: (inout AgentSkill) -> Void) {
        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        mutate(&skills[index])
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(skills) {
            try? data.write(to: Self.resolvedFileURL, options: .atomic)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "skills.lastPersist")
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
