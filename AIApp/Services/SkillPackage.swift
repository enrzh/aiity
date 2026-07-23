import Foundation

/// Parsed Claude/Cursor-style skill package from a SKILL.md (optional YAML frontmatter).
struct SkillPackageDocument: Equatable {
    var name: String
    var summary: String
    var version: String?
    var instructions: String
    /// Optional remote origin for update/remove bookkeeping.
    var source: String?
}

/// Pure package parsing + GitHub URL resolution. Install/persist lives on SkillStore.
enum SkillPackage {

    /// Parse SKILL.md markdown. Supports optional `---` YAML frontmatter with
    /// keys: name, summary/description, version.
    static func parse(markdown: String, source: String? = nil) -> SkillPackageDocument? {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var body = trimmed
        var meta: [String: String] = [:]

        if trimmed.hasPrefix("---") {
            let afterFirst = trimmed.dropFirst(3)
            if let endRange = afterFirst.range(of: "\n---") {
                let yaml = String(afterFirst[..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                meta = parseSimpleYAML(yaml)
                body = String(afterFirst[endRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let name = meta["name"]
            ?? firstHeading(in: body)
            ?? source.flatMap { URL(string: $0)?.deletingPathExtension().lastPathComponent }
            ?? "Skill"
        let summary = meta["summary"]
            ?? meta["description"]
            ?? String(body.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty && !$0.hasPrefix("#") })?
                .prefix(120) ?? "Skill package")
        let version = meta["version"]
        let instructions = body.isEmpty ? trimmed : body
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return SkillPackageDocument(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            version: version,
            instructions: instructions,
            source: source
        )
    }

    /// Two-pass injection: pack **all enabled imported skills first** (up to ~75% of
    /// budget), then fill remaining space with built-ins. Fixes “imported skill
    /// shows in list but never reaches the model” when UI-Design Pro ate the budget.
    static func promptInjectionPreferringImports(from skills: [AgentSkill], maxChars: Int) -> String {
        let enabled = skills.filter(\.enabled)
        guard !enabled.isEmpty else { return "" }
        let imported = prioritized(enabled.filter { !$0.builtin })
        let builtins = prioritized(enabled.filter(\.builtin))
        // Give imports ~75% of the budget, floored at 1200 — but never more than
        // the total budget, or a small maxChars would be silently exceeded.
        let importBudget = min(maxChars, max(1_200, Int(Double(maxChars) * 0.75)))
        let importBlock = packSkills(imported, maxChars: importBudget, tag: "imported — high priority")
        let rest = max(0, maxChars - importBlock.count - 4)
        let builtinBlock = packSkills(builtins, maxChars: rest, tag: "built-in")
        return [importBlock, builtinBlock].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Formats enabled skills (imported first). Used by tests and simple callers.
    static func promptInjection(from skills: [AgentSkill], maxChars: Int = .max) -> String {
        promptInjectionPreferringImports(from: skills, maxChars: maxChars == .max ? 1_000_000 : maxChars)
    }

    private static func packSkills(_ skills: [AgentSkill], maxChars: Int, tag: String) -> String {
        guard maxChars > 80, !skills.isEmpty else { return "" }
        var parts: [String] = []
        var used = 0
        for skill in skills {
            var header = "## Skill: \(skill.name) [\(tag)]"
            if let ver = skill.packageVersion, !ver.isEmpty {
                header += " (v\(ver))"
            }
            let block = """
            \(header)
            Apply this skill whenever it is relevant to the user's request. Do not ignore it.
            \(skill.instructions)
            """
            let next = used == 0 ? block : "\n\n" + block
            if used + next.count > maxChars {
                if used == 0 {
                    parts.append(String(block.prefix(max(200, maxChars - 20))) + "\n…")
                }
                break
            }
            parts.append(block)
            used += next.count
        }
        return parts.joined(separator: "\n\n")
    }

    /// Imported first, then built-ins (stable by name within group).
    static func prioritized(_ skills: [AgentSkill]) -> [AgentSkill] {
        skills.sorted { a, b in
            if a.builtin != b.builtin { return !a.builtin && b.builtin }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Short roster of enabled skill names (for local models / tight budgets).
    static func enabledRoster(from skills: [AgentSkill]) -> String {
        let enabled = prioritized(skills.filter(\.enabled))
        guard !enabled.isEmpty else { return "" }
        let names = enabled.map { $0.builtin ? $0.name : "\($0.name)*" }
        return "Enabled skills (* = imported, highest priority): " + names.joined(separator: ", ") + "."
    }

    // MARK: - GitHub source → raw content URL

    /// All plausible raw URLs for a install spec (tries path variants).
    static func candidateInstallURLs(_ spec: String, defaultBranch: String = "main") -> [URL] {
        let raw = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }

        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            if let url = URL(string: raw) {
                if let host = url.host?.lowercased(), host.contains("github.com"),
                   let converted = githubWebURLToRaw(url, defaultBranch: defaultBranch) {
                    return [converted]
                }
                return [url]
            }
            return []
        }

        var branch = defaultBranch
        var pathPart = raw
        if let at = raw.lastIndex(of: "@") {
            branch = String(raw[raw.index(after: at)...]).trimmingCharacters(in: .whitespaces)
            pathPart = String(raw[..<at])
        }
        let pieces = pathPart.split(separator: "/").map(String.init)
        guard pieces.count >= 2 else { return [] }
        let owner = pieces[0]
        let repo = pieces[1]
        let rest = Array(pieces.suffix(from: min(2, pieces.count)))
        let joined = rest.joined(separator: "/")

        // Anthropic skills live under skills/<name>/SKILL.md — try that first
        // when the user (or our old recs) omitted the extra `skills/` segment.
        var pathVariants: [String] = []
        if joined.isEmpty {
            pathVariants = ["SKILL.md"]
        } else if joined.lowercased().hasSuffix(".md") {
            pathVariants = [joined]
        } else {
            pathVariants = [
                "\(joined)/SKILL.md",
                "skills/\(joined)/SKILL.md",
                "\(joined).md",
            ]
            // If already starts with skills/, don't double it
            if joined.hasPrefix("skills/") {
                let withoutPrefix = String(joined.dropFirst("skills/".count))
                pathVariants = ["\(joined)/SKILL.md", "\(withoutPrefix)/SKILL.md"]
            }
        }

        var urls: [URL] = []
        for branchTry in [branch, "main", "master"] {
            for path in pathVariants {
                let s = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branchTry)/\(path)"
                if let u = URL(string: s), !urls.contains(u) { urls.append(u) }
            }
        }
        return urls
    }

    /// Accepts:
    /// - `owner/repo`
    /// - `owner/repo/path/to/skill` (folder; appends SKILL.md)
    /// - `owner/repo@branch` or `owner/repo/path@branch`
    /// - full `https://github.com/owner/repo/...` or raw.githubusercontent URLs
    /// - any other https URL to a markdown file
    static func resolveInstallURL(_ spec: String, defaultBranch: String = "main") -> Result<URL, ProbeFailure> {
        let urls = candidateInstallURLs(spec, defaultBranch: defaultBranch)
        guard let first = urls.first else {
            return .failure(ProbeFailure(message: "Format: owner/repo oder owner/repo/pfad/zum/skill"))
        }
        return .success(first)
    }

    private static func githubWebURLToRaw(_ url: URL, defaultBranch: String) -> URL? {
        // https://github.com/owner/repo/blob/branch/path/SKILL.md
        // https://github.com/owner/repo/tree/branch/path
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let repo = parts[1]
        if parts.count >= 5, parts[2] == "blob" {
            let branch = parts[3]
            let filePath = parts.dropFirst(4).joined(separator: "/")
            return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(filePath)")
        }
        if parts.count >= 4, parts[2] == "tree" {
            let branch = parts[3]
            var dir = parts.dropFirst(4).joined(separator: "/")
            if dir.isEmpty { dir = "SKILL.md" }
            else if !dir.lowercased().hasSuffix(".md") { dir += "/SKILL.md" }
            return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(dir)")
        }
        // https://github.com/owner/repo → main/SKILL.md
        if parts.count == 2 {
            return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(defaultBranch)/SKILL.md")
        }
        return nil
    }

    private static func parseSimpleYAML(_ yaml: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    private static func firstHeading(in markdown: String) -> String? {
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            }
        }
        return nil
    }
}
