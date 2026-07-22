import XCTest
@testable import AIApp

@MainActor
final class SkillPackageTests: XCTestCase {

    override func setUp() {
        super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiity-skills-test-\(UUID().uuidString).json")
        SkillStore.fileURLOverride = url
    }

    override func tearDown() {
        if let url = SkillStore.fileURLOverride {
            try? FileManager.default.removeItem(at: url)
        }
        SkillStore.fileURLOverride = nil
        super.tearDown()
    }

    func testParseFrontmatterPackage() {
        let md = """
        ---
        name: Widget Craft
        summary: Builds polished widgets
        version: 1.2.0
        ---
        # Details
        Always use cards and 44px targets.
        """
        let doc = SkillPackage.parse(markdown: md, source: "acme/skills/widget")
        XCTAssertEqual(doc?.name, "Widget Craft")
        XCTAssertEqual(doc?.summary, "Builds polished widgets")
        XCTAssertEqual(doc?.version, "1.2.0")
        XCTAssertTrue(doc?.instructions.contains("44px") == true)
        XCTAssertEqual(doc?.source, "acme/skills/widget")
    }

    func testParseHeadingFallback() {
        let md = """
        # Calendar Helper
        Prefer week view.
        """
        let doc = SkillPackage.parse(markdown: md)
        XCTAssertEqual(doc?.name, "Calendar Helper")
        XCTAssertTrue(doc?.instructions.contains("week view") == true)
    }

    func testResolveGitHubOwnerRepo() {
        let urls = SkillPackage.candidateInstallURLs("foo/bar")
        XCTAssertTrue(urls.contains { $0.absoluteString.contains("foo/bar/main/SKILL.md") })
    }

    func testResolveGitHubPathAndBranch() {
        let urls = SkillPackage.candidateInstallURLs("foo/bar/skills/ui@develop")
        XCTAssertTrue(urls.contains {
            $0.absoluteString == "https://raw.githubusercontent.com/foo/bar/develop/skills/ui/SKILL.md"
        })
    }

    func testAnthropicStylePathVariants() {
        // User omits the nested `skills/` folder — we still try skills/<name>/SKILL.md
        let urls = SkillPackage.candidateInstallURLs("anthropics/skills/frontend-design@main")
        XCTAssertTrue(urls.contains {
            $0.absoluteString.contains("anthropics/skills/main/skills/frontend-design/SKILL.md")
        })
    }

    func testResolveGitHubBlobURL() {
        let web = "https://github.com/foo/bar/blob/main/pack/SKILL.md"
        switch SkillPackage.resolveInstallURL(web) {
        case .success(let url):
            XCTAssertEqual(
                url.absoluteString,
                "https://raw.githubusercontent.com/foo/bar/main/pack/SKILL.md"
            )
        case .failure(let fail):
            XCTFail(fail.message)
        }
    }

    func testPromptInjectionIncludesEnabledOnly() {
        let skills = [
            AgentSkill(name: "A", summary: "a", instructions: "Do A things.", enabled: true),
            AgentSkill(name: "B", summary: "b", instructions: "Do B things.", enabled: false),
        ]
        let text = SkillPackage.promptInjection(from: skills)
        XCTAssertTrue(text.contains("Do A things."))
        XCTAssertFalse(text.contains("Do B things."))
        XCTAssertTrue(text.contains("Apply this skill"))
    }

    func testImportedSkillsBeatBuiltinsInBudget() {
        let hugeBuiltin = AgentSkill(
            name: "UI-Design Pro",
            summary: "big",
            instructions: String(repeating: "BUILTIN ", count: 400),
            enabled: true,
            builtin: true
        )
        let imported = AgentSkill(
            name: "My Import",
            summary: "custom",
            instructions: "UNIQUE_IMPORTED_MARKER follow these custom rules always.",
            enabled: true,
            builtin: false
        )
        // Tight budget that cannot fit both fully — import must win.
        let text = SkillPackage.promptInjectionPreferringImports(
            from: [hugeBuiltin, imported],
            maxChars: 600
        )
        XCTAssertTrue(text.contains("UNIQUE_IMPORTED_MARKER"), "imported skill body must be present")
        XCTAssertTrue(text.contains("My Import"))
        XCTAssertTrue(text.contains("imported"))
    }

    func testPromptInjectionRespectsMaxCharsPerSkill() {
        let long = String(repeating: "x", count: 5000)
        let skills = [
            AgentSkill(name: "Long", summary: "l", instructions: long, enabled: true, builtin: false),
            AgentSkill(name: "Short", summary: "s", instructions: "short body", enabled: true, builtin: false),
        ]
        let text = SkillPackage.promptInjection(from: skills, maxChars: 800)
        XCTAssertTrue(text.contains("Skill: Long"))
        XCTAssertTrue(text.count <= 900)
    }

    func testInstallPackageEnableDisableInjection() {
        let store = SkillStore()
        XCTAssertFalse(store.skills.isEmpty)

        let md = """
        ---
        name: Test Pack
        summary: For unit tests
        version: 0.1.0
        ---
        Say hello from the test pack.
        """
        let installed = store.installPackage(markdown: md, source: "test/repo/skill")
        XCTAssertEqual(installed?.name, "Test Pack")
        XCTAssertEqual(installed?.packageVersion, "0.1.0")
        XCTAssertEqual(installed?.source, "test/repo/skill")

        let enabledText = SkillStore.enabledInstructions()
        XCTAssertTrue(enabledText.contains("Test Pack"), enabledText)
        XCTAssertTrue(enabledText.contains("Say hello from the test pack"), enabledText)

        if let skill = store.skills.first(where: { $0.name == "Test Pack" }) {
            store.toggle(skill)
        }
        let disabledText = SkillStore.enabledInstructions()
        XCTAssertFalse(disabledText.contains("Say hello from the test pack"), disabledText)

        var skills = store.skills
        if let idx = skills.firstIndex(where: { $0.name == "Test Pack" }) {
            skills[idx].enabled = true
        }
        let injected = SkillPackage.promptInjection(from: skills)
        XCTAssertTrue(injected.contains("v0.1.0"))
        XCTAssertTrue(injected.contains("Say hello"))

        if let skill = store.skills.first(where: { $0.name == "Test Pack" }) {
            store.remove(skill)
        }
        XCTAssertNil(store.skills.first(where: { $0.name == "Test Pack" }))
    }
}
