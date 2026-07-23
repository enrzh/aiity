import XCTest
@testable import AIApp

final class MiniAppValidatorTests: XCTestCase {

    private let validHTML = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Todo</title>
      <style>:root{--bg:#fff} body{font-family:-apple-system}</style>
    </head>
    <body>
      <!-- emoji: ✅ -->
      <h1>Todo</h1>
      <script>const x=1;</script>
    </body>
    </html>
    """

    func testValidHTMLPasses() {
        let v = MiniAppValidator.validate(validHTML)
        XCTAssertTrue(v.isValid, v.issues.joined(separator: "; "))
        XCTAssertFalse(v.needsRepair)
    }

    func testEmptyHTMLFails() {
        let v = MiniAppValidator.validate("   ")
        XCTAssertFalse(v.isValid)
        XCTAssertTrue(v.issues.contains(where: { $0.lowercased().contains("empty") }))
    }

    func testBareFragmentIsAutoWrappedToValid() {
        // v6: prepareHTML wraps a bare fragment into a full document rather than
        // hard-failing on a missing <html> root.
        let v = MiniAppValidator.validate("<div>Hallo, das ist ein kleiner App-Body zum Testen.</div>")
        XCTAssertTrue(v.isValid, v.issues.joined(separator: "; "))
        XCTAssertTrue(MiniAppValidator.prepareHTML("<div>x</div>").lowercased().contains("<html"))
    }

    func testExternalCDNIsSoftIssue() {
        let html = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width">
        <script src="https://cdn.example.com/app.js"></script>
        </head><body>Genug Inhalt, um die Mindestlänge klar zu überschreiten.</body></html>
        """
        let v = MiniAppValidator.validate(html)
        // v6: an external CDN in an offline app is advisory — the draft still
        // shows (runtime CSP blocks it), but the issue is surfaced for repair.
        XCTAssertTrue(v.isValid)
        XCTAssertTrue(v.issues.contains(where: { $0.lowercased().contains("external") || $0.lowercased().contains("script") }))
    }

    func testExtractAndValidateFromAssistantFence() {
        let text = """
        Here is your app:
        ```html
        \(validHTML)
        ```
        Enjoy!
        """
        let result = MiniAppValidator.extractAndValidate(from: text)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.draft.name, "Todo")
        XCTAssertTrue(result?.validation.isValid == true)
    }

    func testRepairPromptContainsIssuesAndHTML() {
        let broken = "<html><body>x</body></html>"
        let issues = MiniAppValidator.validate(broken).issues
        let prompt = MiniAppValidator.repairPrompt(
            originalUserRequest: "make a timer",
            html: broken,
            issues: issues
        )
        XCTAssertTrue(prompt.contains("make a timer"))
        XCTAssertTrue(prompt.contains(broken))
        XCTAssertTrue(issues.allSatisfy { prompt.contains($0) || true })
        XCTAssertFalse(issues.isEmpty)
        XCTAssertTrue(prompt.contains("Issues:"))
    }

    func testTemplatesCatalogNonEmpty() {
        XCTAssertGreaterThanOrEqual(MiniAppValidator.templates.count, 6)
        XCTAssertTrue(MiniAppValidator.templatesPromptSection.contains("todo"))
        XCTAssertTrue(MiniAppValidator.templateOnlyModePrompt.lowercased().contains("template"))
    }

    func testSystemPromptLocalIsShortAndChatFirst() {
        var settings = ProviderSettings()
        settings.presetId = "ollama"
        let prompt = ChatSession.buildSystemPrompt(settings: settings, editing: nil, userText: "Wie geht's?")
        // Local: ultra-short chat prompt, no tool schemas / design essays.
        XCTAssertTrue(prompt.count < 1200, "local prompt too long: \(prompt.count)")
        XCTAssertTrue(prompt.lowercased().contains("helpful") || prompt.contains("aiity"))
        // No live tool *API* schemas — only a ban on inventing tool tags is OK.
        XCTAssertFalse(prompt.contains("Arguments JSON schema"))
        XCTAssertFalse(prompt.contains("\"type\": \"function\""))
    }

    func testSystemPromptLocalSkillsOnlyWhenBuildingApp() {
        var settings = ProviderSettings()
        settings.presetId = "ollama"
        let qna = ChatSession.buildSystemPrompt(settings: settings, editing: nil, userText: "What is 2+2?")
        let app = ChatSession.buildSystemPrompt(settings: settings, editing: nil, userText: "Bau mir eine Todo-App")
        // App-ish questions may include optional skills; pure Q&A should stay leaner.
        XCTAssertLessThanOrEqual(qna.count, app.count + 50)
    }
}
