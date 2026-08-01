import Foundation

/// Result of checking a generated mini-app HTML document against the sandbox rules.
struct MiniAppValidation: Equatable {
    var isValid: Bool
    var issues: [String]

    var needsRepair: Bool { !isValid && !issues.isEmpty }
}

/// Catalog entry for template-first mini-app generation (raises the quality floor).
struct MiniAppTemplate: Identifiable, Equatable {
    var id: String
    var name: String
    var summary: String
    /// Scaffold the agent should fill rather than inventing CSS from zero.
    var scaffoldHint: String
}

/// Validates self-contained mini-app HTML and builds repair prompts.
/// Templates steer weaker models toward known-good patterns.
enum MiniAppValidator {

    static let templates: [MiniAppTemplate] = [
        MiniAppTemplate(
            id: "todo",
            name: "Todo / Checklist",
            summary: "Add/complete/delete items with persistence",
            scaffoldHint: "App shell with list + input + empty state; persist items via miniapp.storage."
        ),
        MiniAppTemplate(
            id: "tracker",
            name: "Daily tracker",
            summary: "Log values per day with simple totals",
            scaffoldHint: "Date-keyed entries, total row, dark mode CSS variables."
        ),
        MiniAppTemplate(
            id: "timer",
            name: "Timer / reminder",
            summary: "Countdown with optional miniapp.notify",
            scaffoldHint: "Start/pause/reset; schedule notify(inSeconds) when running ends."
        ),
        MiniAppTemplate(
            id: "quiz",
            name: "Quiz",
            summary: "Questions, score, restart",
            scaffoldHint: "Array of Q&A, progress indicator, score screen."
        ),
        MiniAppTemplate(
            id: "calculator",
            name: "Calculator",
            summary: "Basic arithmetic with safe eval",
            scaffoldHint: "Button grid, display, no eval of free text — explicit ops only."
        ),
        MiniAppTemplate(
            id: "list-form",
            name: "List + form",
            summary: "CRUD records with fields",
            scaffoldHint: "Form fields, validation, list of cards, edit/delete."
        ),
    ]

    /// System-prompt block listing templates (always safe to append).
    static var templatesPromptSection: String {
        let lines = templates.map { "- `\($0.id)` — \($0.name): \($0.summary). Scaffold: \($0.scaffoldHint)" }
        return """
        # Mini-app templates (prefer these)
        When building a mini-app, pick the closest template id and adapt it — do not invent a brand-new design system unless the user asks for something unique.
        \(lines.joined(separator: "\n"))
        For Quick/template mode: reuse the design system skill (CSS variables, 44px targets, dark mode). Output ONE complete ```html document.
        """
    }

    /// Extra system guidance when the runtime is chat/template-oriented (local/MLX).
    static var templateOnlyModePrompt: String {
        """
        # Capability: template mini-apps only
        This model/runtime is best for chat, skills, and template-based mini-apps.
        Do NOT invent complex free-form Pro apps (3D games, multi-view SPAs). Prefer a listed template id and keep the app small and complete.
        If the user asks for something far beyond a template, explain limits and offer the closest template.
        """
    }

    /// Auto-fix common model omissions so drafts still open in the sandbox.
    static func prepareHTML(_ raw: String) -> String {
        var html = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !html.isEmpty else { return html }
        let lower = html.lowercased()
        if !(lower.contains("<html") || lower.contains("<!doctype")) {
            html = """
            <!DOCTYPE html>
            <html lang="de">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
            <title>Mini-App</title>
            <!-- emoji: ✨ -->
            <style>
              :root { color-scheme: light dark; font-family: -apple-system, system-ui, sans-serif; }
              body { margin: 0; padding: 16px; padding-bottom: env(safe-area-inset-bottom); }
            </style>
            </head>
            <body>
            \(html)
            </body>
            </html>
            """
        } else {
            if !lower.contains("viewport") {
                if let head = html.range(of: "<head>", options: .caseInsensitive) {
                    html.insert(
                        contentsOf: "\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n",
                        at: head.upperBound
                    )
                }
            }
            if !html.lowercased().contains("</body>") {
                html += "\n</body>"
            }
            if !html.lowercased().contains("</html>") {
                html += "\n</html>"
            }
        }
        return html
    }

    static func validate(_ html: String) -> MiniAppValidation {
        var issues: [String] = []
        let prepared = prepareHTML(html)
        let trimmed = prepared.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if trimmed.isEmpty {
            return MiniAppValidation(isValid: false, issues: ["HTML is empty."])
        }
        // After prepareHTML these should usually pass — only hard-fail empty shell.
        if trimmed.count < 80 {
            issues.append("HTML too short to be a usable mini-app.")
        }
        let capability = MiniAppCapability.from(html: trimmed)
        if capability == .offline {
            let externalPatterns = [
                "https://", "http://", "//cdn", "unpkg.com", "jsdelivr", "googleapis", "fontawesome",
            ]
            for pattern in externalPatterns {
                // Allow inside comments only roughly — still flag real CDN usage.
                if lower.contains(pattern), !lower.contains("capability: network"), !lower.contains("capability: browser") {
                    // Soft: still valid for preview if we strip? Keep as issue but allow draft show.
                    issues.append(String(localized: "External URL (\(pattern)) — besser `<!-- capability: network -->` oder inline."))
                    break
                }
            }
            if lower.range(of: #"<script[^>]+src\s*="#, options: .regularExpression) != nil {
                issues.append("External <script src> — bitte inline JS.")
            }
            if lower.range(of: #"<link[^>]+href\s*="#, options: .regularExpression) != nil {
                issues.append("External <link href> — bitte inline CSS.")
            }
        } else if capability == .network {
            if lower.contains("<iframe") {
                issues.append("iframe requires `<!-- capability: browser -->`.")
            }
        }

        // Soft issues (CDN etc.) no longer block the draft card — only empty/tiny HTML does.
        let hardFail = trimmed.isEmpty || trimmed.count < 80
        return MiniAppValidation(isValid: !hardFail, issues: issues)
    }

    /// Prompt the model should receive to fix a broken mini-app in one shot.
    static func repairPrompt(originalUserRequest: String? = nil, html: String, issues: [String]) -> String {
        let issueList = issues.map { "- \($0)" }.joined(separator: "\n")
        var text = """
        The mini-app HTML you produced failed validation. Fix ALL issues and output the FULL corrected document in one ```html fence (no external URLs, single file, viewport, head/body).

        Issues:
        \(issueList)
        """
        if let originalUserRequest, !originalUserRequest.isEmpty {
            text += "\n\nOriginal user request:\n\(originalUserRequest)"
        }
        text += "\n\nBroken HTML to repair:\n```html\n\(html)\n```"
        return text
    }

    /// Extract html fence then validate — used by agent after a model turn.
    static func extractAndValidate(from assistantText: String) -> (draft: MiniAppDraft, validation: MiniAppValidation)? {
        guard let draft = MiniAppDraft.extract(from: assistantText) else { return nil }
        return (draft, validate(draft.html))
    }
}
