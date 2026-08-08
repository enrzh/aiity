import Foundation

/// Curated skill sources. Prefer **bundled** packages (always installable offline)
/// with correct remote URLs as secondary.
struct SkillRecommendation: Identifiable, Equatable {
    var id: String { installKey }
    var title: String
    var blurb: String
    /// Install key: `bundled:<name>` or GitHub-style `owner/repo/path@branch`.
    var installKey: String
    var systemImage: String
    /// Remote path for updates (optional).
    var remoteSource: String?
}

enum SkillRecommendations {
    /// Bundled presets for the mini-app pipeline (offline-only, no upstream repo).
    /// Blurbs mirror each package's frontmatter `description`.
    static let miniApps: [SkillRecommendation] = [
        SkillRecommendation(
            title: "Formulare & Tracker Pro",
            blurb: "Formular- und Tracker-Mini-Apps: Inline-Validierung, deutsche Zahlen- und Datumsformate, Speichern bei jeder Eingabe, Rückgängig nach dem Löschen.",
            installKey: "bundled:formulare-tracker",
            systemImage: "list.bullet.clipboard",
            remoteSource: nil
        ),
        SkillRecommendation(
            title: "Geld & Prozent",
            blurb: "Cent-genaue Geldrechnung mit deutschen Formaten – MwSt. 19 %/7 %, Prozente, Rabatt, Trinkgeld und Rechnungen fair teilen.",
            installKey: "bundled:geld-prozent",
            systemImage: "eurosign.circle",
            remoteSource: nil
        ),
        SkillRecommendation(
            title: "Termine & Erinnerungen",
            blurb: "Zeitumstellungssichere Datumslogik ohne Bibliotheken, Serien, Streaks und lokale Benachrichtigungen für Mini-Apps.",
            installKey: "bundled:termine-erinnerungen",
            systemImage: "calendar.badge.clock",
            remoteSource: nil
        ),
        SkillRecommendation(
            title: "Daten-Export & Backup",
            blurb: "CSV/JSON-Export, Kopieren in die Zwischenablage, Import per Einfügen, versionierte Backups mit Wiederherstellung.",
            installKey: "bundled:daten-export",
            systemImage: "square.and.arrow.up",
            remoteSource: nil
        ),
        SkillRecommendation(
            title: "API-Apps sicher bauen",
            blurb: "Baut robuste Netzwerk-Mini-Apps: Lade-, Leer- und Fehlerzustände, Timeouts, Offline-Cache und sichere API-Key-Abfrage — ohne hartkodierte Schlüssel.",
            installKey: "bundled:api-apps",
            systemImage: "antenna.radiowaves.left.and.right",
            remoteSource: nil
        ),
        SkillRecommendation(
            title: "Web-Wrapper Pro",
            blurb: "Webseiten und interne Tools als Mini-Apps einbinden – Login-Seiten per Vollnavigation, Quick-Link-Startseiten und Embeds mit dauerhafter Anmeldung.",
            installKey: "bundled:web-wrapper",
            systemImage: "safari",
            remoteSource: nil
        ),
        SkillRecommendation(
            title: "Lern-Apps & Karteikarten",
            blurb: "Karteikarten- und Quiz-Apps mit echter Spaced-Repetition-Logik, Tages-Stapel, Statistik und Import per Einfügen.",
            installKey: "bundled:lern-apps",
            systemImage: "rectangle.stack",
            remoteSource: nil
        ),
        SkillRecommendation(
            title: "Barrierefreiheit (A11y)",
            blurb: "Macht jede generierte Mini-App standardmäßig barrierefrei — semantische Bedienelemente, VoiceOver-Labels, Kontrast, sichtbarer Fokus und reduzierte Bewegung.",
            installKey: "bundled:barrierefreiheit",
            systemImage: "accessibility",
            remoteSource: nil
        ),
    ]

    /// Every recommendation (used by tests and any flat consumer).
    static var all: [SkillRecommendation] { miniApps + anthropic }

    /// Real paths in anthropics/skills are under `skills/<name>/SKILL.md`.
    static let anthropic: [SkillRecommendation] = [
        SkillRecommendation(
            title: "Frontend Design",
            blurb: "Anthropic — distinctive UI, typography, not generic AI look.",
            installKey: "bundled:frontend-design",
            systemImage: "paintbrush",
            remoteSource: "anthropics/skills/skills/frontend-design@main"
        ),
        SkillRecommendation(
            title: "Skill Creator",
            blurb: "Anthropic — how to author good agent skills.",
            installKey: "bundled:skill-creator",
            systemImage: "star.circle",
            remoteSource: "anthropics/skills/skills/skill-creator@main"
        ),
        SkillRecommendation(
            title: "MCP Builder",
            blurb: "Anthropic — building MCP tools & servers.",
            installKey: "bundled:mcp-builder",
            systemImage: "wrench.and.screwdriver",
            remoteSource: "anthropics/skills/skills/mcp-builder@main"
        ),
        SkillRecommendation(
            title: "Doc Co-authoring",
            blurb: "Anthropic — collaborative documentation.",
            installKey: "bundled:doc-coauthoring",
            systemImage: "doc.text",
            remoteSource: "anthropics/skills/skills/doc-coauthoring@main"
        ),
        SkillRecommendation(
            title: "Webapp Testing",
            blurb: "Anthropic — testing web apps systematically.",
            installKey: "bundled:webapp-testing",
            systemImage: "checkmark.shield",
            remoteSource: "anthropics/skills/skills/webapp-testing@main"
        ),
        SkillRecommendation(
            title: "Brand Guidelines",
            blurb: "Anthropic — consistent brand styling.",
            installKey: "bundled:brand-guidelines",
            systemImage: "seal",
            remoteSource: "anthropics/skills/skills/brand-guidelines@main"
        ),
        SkillRecommendation(
            title: "Canvas Design",
            blurb: "Anthropic — canvas / visual layout skill.",
            installKey: "bundled:canvas-design",
            systemImage: "rectangle.3.group",
            remoteSource: "anthropics/skills/skills/canvas-design@main"
        ),
        SkillRecommendation(
            title: "PDF",
            blurb: "Anthropic — PDF creation & handling.",
            installKey: "bundled:pdf",
            systemImage: "doc.richtext",
            remoteSource: "anthropics/skills/skills/pdf@main"
        ),
    ]
}

/// Loads SKILL.md packages shipped inside the app bundle.
enum BundledSkills {
    static func markdown(named name: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "bundled:", with: "")
        // Resources/BundledSkills/<name>.md
        if let url = Bundle.main.url(forResource: clean, withExtension: "md", subdirectory: "BundledSkills")
            ?? Bundle.main.url(forResource: clean, withExtension: "md") {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return nil
    }

    static var availableNames: [String] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: "BundledSkills") else {
            // Flat copy in bundle root
            return Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: nil)?
                .map { $0.deletingPathExtension().lastPathComponent } ?? []
        }
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }
}
