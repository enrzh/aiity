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

    func testAddPreservesConflictingUserSkill() {
        let store = SkillStore()
        // User-authored skill (no source).
        store.add(name: "PDF", instructions: "meine eigenen Notizen")
        XCTAssertEqual(store.skills.filter { $0.name == "PDF" }.count, 1)

        // A package from a DIFFERENT origin must not silently delete it.
        store.add(name: "PDF", instructions: "package content", source: "github:acme/pdf")
        let names = store.skills.filter { !$0.builtin }.map(\.name)
        XCTAssertTrue(names.contains("PDF"), "incoming package keeps the name")
        XCTAssertTrue(names.contains("PDF (lokal)"), "user's edited skill is preserved, not deleted")
        XCTAssertTrue(
            store.skills.contains { $0.name == "PDF (lokal)" && $0.instructions == "meine eigenen Notizen" }
        )

        // Re-installing from the SAME origin is an upgrade: replace, don't fork.
        store.add(name: "PDF", instructions: "package v2", source: "github:acme/pdf")
        XCTAssertEqual(store.skills.filter { $0.name == "PDF" }.count, 1)
        XCTAssertEqual(store.skills.first { $0.name == "PDF" }?.instructions, "package v2")
        XCTAssertEqual(store.skills.filter { $0.name.hasPrefix("PDF (lokal") }.count, 1,
                       "upgrade must not create another fork")
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

    func testDeflatedZipImport() throws {
        // A real DEFLATE-compressed zip containing skills/deflated/SKILL.md + README.md.
        let b64 = "UEsDBBQAAAAIAGe/91wqQ/IzbwAAAOMHAAAYAAAAc2tpbGxzL2RlZmxhdGVkL1NLSUxMLm1k7cvBDcIwDAXQe6b4C4RTT70hMQArWIlLEXUS2YmgTE+m4OTz04sxhkLCK268HdQ5407pFWyIkJ4rNq0CQqrSlM2mf58txNmux5tOwzCG1lHypESaDVQylqV90OtIOzrpg7td4MGDBw8ePHj4W/gBUEsDBBQAAAAIAGe/91yHcuC0CwAAAAkAAAAJAAAAUkVBRE1FLm1ky0zPyy9KVchNBQBQSwECFAMUAAAACABnv/dcKkPyM28AAADjBwAAGAAAAAAAAAAAAAAAgAEAAAAAc2tpbGxzL2RlZmxhdGVkL1NLSUxMLm1kUEsBAhQDFAAAAAgAZ7/3XIdy4LQLAAAACQAAAAkAAAAAAAAAAAAAAIABpQAAAFJFQURNRS5tZFBLBQYAAAAAAgACAH0AAADXAAAAAAA="
        let data = Data(base64Encoded: b64)!
        let md = try ZipSkillExtractor.skillMarkdown(from: data)
        XCTAssertTrue(md.contains("Deflated Pack"), md)
        XCTAssertTrue(md.contains("44px touch targets"), "inflated body should be present")
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

    // MARK: - Bundled mini-app presets

    /// The 8 bundled mini-app preset packages (Resources/BundledSkills/<name>.md).
    private static let miniAppSkillNames = [
        "formulare-tracker", "geld-prozent", "termine-erinnerungen", "daten-export",
        "api-apps", "web-wrapper", "lern-apps", "barrierefreiheit",
    ]

    func testBundledMiniAppSkillsParseWithGermanDescriptions() throws {
        for name in Self.miniAppSkillNames {
            let md = try XCTUnwrap(
                BundledSkills.markdown(named: "bundled:\(name)"),
                "\(name).md missing from app bundle (BundledSkills)"
            )
            let doc = try XCTUnwrap(SkillPackage.parse(markdown: md), "\(name) must parse")
            XCTAssertEqual(doc.name, name, "frontmatter name must match the file name")
            // Version present proves the frontmatter block was actually parsed
            // (not swallowed into the body).
            XCTAssertNotNil(doc.version, "\(name): frontmatter did not parse")
            XCTAssertFalse(doc.summary.isEmpty, "\(name): empty description")
            XCTAssertFalse(doc.summary.hasPrefix("#"), "\(name): summary fell back to body")
            XCTAssertFalse(doc.instructions.isEmpty, "\(name): empty body")
        }
    }

    func testBundledMiniAppSkillBodiesFitInjectionBudget() throws {
        // Each preset must fit even the compact skill budget on its own, so a
        // single enabled preset is never truncated mid-skill.
        for name in Self.miniAppSkillNames {
            let md = try XCTUnwrap(BundledSkills.markdown(named: "bundled:\(name)"))
            let doc = try XCTUnwrap(SkillPackage.parse(markdown: md))
            XCTAssertLessThanOrEqual(
                doc.instructions.count, ChatSession.skillCharBudgetCompact,
                "\(name): body exceeds the compact skill budget"
            )
            XCTAssertLessThanOrEqual(
                doc.instructions.count, ChatSession.skillCharBudgetCloud,
                "\(name): body exceeds the cloud skill budget"
            )
        }
    }

    func testBundledMiniAppSkillNamesUnique() throws {
        var names: [String] = []
        for name in Self.miniAppSkillNames {
            let md = try XCTUnwrap(BundledSkills.markdown(named: "bundled:\(name)"))
            let doc = try XCTUnwrap(SkillPackage.parse(markdown: md))
            names.append(doc.name)
        }
        XCTAssertEqual(Set(names).count, names.count, "duplicate parsed skill names")
        let builtinNames = Set(SkillStore.builtins.map(\.name))
        XCTAssertTrue(builtinNames.isDisjoint(with: names),
                      "preset names must not collide with builtins (add() would fork)")
    }

    func testEveryBundledRecommendationResolvesToBundledResource() {
        // Guards against a recommendation pointing at a missing .md — the
        // exact failure behind "Gebündelter Skill … nicht im App-Bundle".
        let bundled = SkillRecommendations.all.filter { $0.installKey.hasPrefix("bundled:") }
        XCTAssertGreaterThanOrEqual(bundled.count, 16, "8 anthropic + 8 mini-app presets expected")
        for rec in bundled {
            XCTAssertNotNil(
                BundledSkills.markdown(named: rec.installKey),
                "\(rec.installKey) does not resolve to a bundled resource"
            )
        }
        // The mini-app group is bundled-only by design (no upstream repo).
        for rec in SkillRecommendations.miniApps {
            XCTAssertNil(rec.remoteSource, "\(rec.installKey): mini-app presets have no remote source")
        }
    }

    func testInstallBundledMiniAppSkillEnablesInjection() async {
        let store = SkillStore()
        await store.install(from: "bundled:geld-prozent")
        XCTAssertNil(store.errorMessage)
        let installed = store.skills.first { $0.name == "geld-prozent" }
        XCTAssertNotNil(installed, "install(from: bundled:) must add the skill")
        XCTAssertEqual(installed?.enabled, true)
        XCTAssertEqual(installed?.source, "bundled:geld-prozent")
        let injected = SkillStore.enabledInstructions()
        XCTAssertTrue(injected.contains("geld-prozent"), injected.prefix(300).description)
        XCTAssertTrue(injected.contains("integer cents"), "body must reach the prompt")
    }
}
