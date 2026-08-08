import XCTest
@testable import AIApp

/// `SkillRecommendations.remaining(_:installed:)` — installed recommendations
/// must leave the "Empfohlen" lists and return when the skill is deleted.
/// The correspondence under test: a recommendation install writes the bundled
/// frontmatter name (= installKey basename, NOT the display title) as the
/// skill's name and the installKey (or remote spec) as its source.
@MainActor
final class SkillRecommendationFilterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiity-skillrec-test-\(UUID().uuidString).json")
        SkillStore.fileURLOverride = url
    }

    override func tearDown() {
        if let url = SkillStore.fileURLOverride {
            try? FileManager.default.removeItem(at: url)
        }
        SkillStore.fileURLOverride = nil
        super.tearDown()
    }

    private func installedSkill(name: String, source: String?) -> AgentSkill {
        AgentSkill(name: name, summary: "s", instructions: "i", enabled: true, source: source)
    }

    func testHidesExactlyTheInstalledOnes() {
        // What install(from: "bundled:geld-prozent") creates: frontmatter name
        // + installKey source.
        let installed = [installedSkill(name: "geld-prozent", source: "bundled:geld-prozent")]
        let remaining = SkillRecommendations.remaining(SkillRecommendations.miniApps, installed: installed)
        XCTAssertEqual(remaining.count, SkillRecommendations.miniApps.count - 1)
        XCTAssertFalse(remaining.contains { $0.installKey == "bundled:geld-prozent" })
        XCTAssertTrue(remaining.contains { $0.installKey == "bundled:formulare-tracker" },
                      "uninstalled recommendations must stay listed")
    }

    func testEmptyInstalledKeepsEverything() {
        XCTAssertEqual(
            SkillRecommendations.remaining(SkillRecommendations.all, installed: []).map(\.id),
            SkillRecommendations.all.map(\.id)
        )
    }

    func testMatchesRemoteSourceFallbackInstall() {
        // Network-fallback path: install(from: rec.remoteSource) stores the
        // remote spec as source; the recommendation must still disappear.
        let installed = [installedSkill(name: "pdf", source: "anthropics/skills/skills/pdf@main")]
        let remaining = SkillRecommendations.remaining(SkillRecommendations.anthropic, installed: installed)
        XCTAssertFalse(remaining.contains { $0.installKey == "bundled:pdf" })
    }

    func testNameNormalizationTrimsAndLowercases() {
        // Same normalisation as AgentSuggestion.remaining: a re-imported copy
        // whose name differs only in case/whitespace still counts as installed.
        let installed = [installedSkill(name: "  Geld-Prozent \n", source: nil)]
        let remaining = SkillRecommendations.remaining(SkillRecommendations.miniApps, installed: installed)
        XCTAssertFalse(remaining.contains { $0.installKey == "bundled:geld-prozent" })
        XCTAssertEqual(remaining.count, SkillRecommendations.miniApps.count - 1)
    }

    func testDisplayTitleDoesNotHide() {
        // The installed name is the frontmatter name, never the display title
        // — a user-authored skill that happens to carry the pretty title must
        // not swallow the recommendation.
        let installed = [installedSkill(name: "Geld & Prozent", source: nil)]
        let remaining = SkillRecommendations.remaining(SkillRecommendations.miniApps, installed: installed)
        XCTAssertTrue(remaining.contains { $0.installKey == "bundled:geld-prozent" })
    }

    func testBuiltinsNeverHideRecommendations() {
        let builtin = AgentSkill(
            name: "pdf", summary: "s", instructions: "i",
            enabled: true, builtin: true, source: "bundled:pdf"
        )
        let remaining = SkillRecommendations.remaining(SkillRecommendations.anthropic, installed: [builtin])
        XCTAssertTrue(remaining.contains { $0.installKey == "bundled:pdf" })
    }

    func testBothGroupsFilterIndependently() {
        let installed = [
            installedSkill(name: "lern-apps", source: "bundled:lern-apps"),      // miniApps group
            installedSkill(name: "mcp-builder", source: "bundled:mcp-builder"),  // anthropic group
        ]
        let miniApps = SkillRecommendations.remaining(SkillRecommendations.miniApps, installed: installed)
        let anthropic = SkillRecommendations.remaining(SkillRecommendations.anthropic, installed: installed)
        XCTAssertFalse(miniApps.contains { $0.installKey == "bundled:lern-apps" })
        XCTAssertTrue(miniApps.contains { $0.installKey == "bundled:mcp-builder" } == false
                      && miniApps.count == SkillRecommendations.miniApps.count - 1,
                      "the anthropic install must not eat a second mini-app row")
        XCTAssertFalse(anthropic.contains { $0.installKey == "bundled:mcp-builder" })
        XCTAssertEqual(anthropic.count, SkillRecommendations.anthropic.count - 1)
    }

    /// End-to-end against the real store + real bundled package: install a
    /// recommendation → it leaves the list; delete the skill → it returns.
    func testInstallHidesAndDeleteRestores() async throws {
        guard let rec = SkillRecommendations.miniApps.first else {
            return XCTFail("no recommendations to test")
        }
        // Hosted tests run inside the app bundle, so the bundled package must
        // resolve — if not, the recommendation catalog points at nothing.
        try XCTSkipIf(
            BundledSkills.markdown(named: rec.installKey) == nil,
            "bundled package missing from the test host bundle"
        )

        let store = SkillStore()
        XCTAssertTrue(
            SkillRecommendations.remaining(SkillRecommendations.miniApps, installed: store.skills)
                .contains { $0.id == rec.id },
            "fresh store must list the recommendation"
        )

        await store.install(from: rec.installKey)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(
            SkillRecommendations.remaining(SkillRecommendations.miniApps, installed: store.skills)
                .contains { $0.id == rec.id },
            "installed recommendation must leave the list"
        )

        let installed = store.skills.first { !$0.builtin && $0.source == rec.installKey }
        let skill = try XCTUnwrap(installed, "install must record the installKey as source")
        store.remove(skill)
        XCTAssertTrue(
            SkillRecommendations.remaining(SkillRecommendations.miniApps, installed: store.skills)
                .contains { $0.id == rec.id },
            "deleting the skill must bring the recommendation back"
        )
    }

    /// The filter's name matching relies on frontmatter name == installKey
    /// basename for every bundled recommendation — pin that invariant so a
    /// future package rename cannot silently break the hiding.
    func testBundledFrontmatterNamesMatchInstallKeys() throws {
        for rec in SkillRecommendations.all {
            guard let md = BundledSkills.markdown(named: rec.installKey) else {
                continue // covered by ShipReadiness-style bundle checks elsewhere
            }
            let doc = try XCTUnwrap(SkillPackage.parse(markdown: md, source: rec.installKey))
            let basename = rec.installKey.replacingOccurrences(of: "bundled:", with: "")
            XCTAssertEqual(
                doc.name.lowercased(), basename.lowercased(),
                "\(rec.installKey): frontmatter name must equal the installKey basename"
            )
        }
    }
}
