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
    /// Real paths in anthropics/skills are under `skills/<name>/SKILL.md`.
    static let all: [SkillRecommendation] = [
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
