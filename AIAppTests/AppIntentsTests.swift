import XCTest
import AppIntents
@testable import AIApp

// Siri and the Shortcuts app cannot be driven from a unit test, so what is
// pinned here is everything BELOW that boundary: the entity queries the picker
// calls, the name matching Siri's transcription has to survive, and the
// `perform()` bodies the system actually runs in the app process — including
// the promise that none of them starts a model request.

// MARK: - Name matching

final class IntentNameMatchTests: XCTestCase {
    private struct Named { let name: String }

    private func names(_ values: [String], query: String) -> [String] {
        IntentNameMatch.filter(values.map(Named.init), query: query, name: \.name).map(\.name)
    }

    func testAnEmptyQueryReturnsEverything() {
        // Shortcuts asks with an empty string to populate the parameter picker.
        // Returning nothing here IS the "my apps never show up" bug.
        XCTAssertEqual(names(["Timer", "Notizen"], query: ""), ["Timer", "Notizen"])
        XCTAssertEqual(names(["Timer", "Notizen"], query: "   "), ["Timer", "Notizen"])
    }

    func testMatchingIgnoresCaseAndDiacritics() {
        // Siri's transcription rarely carries the umlaut the user typed.
        XCTAssertEqual(names(["Übersetzer"], query: "ubersetzer"), ["Übersetzer"])
        XCTAssertEqual(names(["Übersetzer"], query: "ÜBER"), ["Übersetzer"])
        XCTAssertEqual(names(["Einkaufsliste"], query: " einkaufs "), ["Einkaufsliste"])
    }

    func testPrefixMatchesRankAboveSubstringMatches() {
        // "Liste" should offer the app that starts with it first, not the one
        // that merely contains it further along.
        XCTAssertEqual(
            names(["Einkaufsliste", "Listen-Timer"], query: "liste"),
            ["Listen-Timer", "Einkaufsliste"]
        )
    }

    func testNoMatchReturnsNothingRatherThanEverything() {
        XCTAssertTrue(names(["Timer", "Notizen"], query: "kalender").isEmpty)
    }

    func testAnEmptyCandidateSetStaysEmpty() {
        XCTAssertTrue(names([], query: "").isEmpty)
        XCTAssertTrue(names([], query: "timer").isEmpty)
    }
}

// MARK: - The mini-app snapshot + its entity query

final class MiniAppIndexTests: XCTestCase {
    private var directory: URL!
    private var previousURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousURL = MiniAppIndex.storageURL
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniapp-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        MiniAppIndex.storageURL = directory.appendingPathComponent("miniapp-index.json")
    }

    override func tearDownWithError() throws {
        MiniAppIndex.storageURL = previousURL
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testAMissingFileReadsAsAnEmptyLibrary() {
        XCTAssertTrue(MiniAppIndex.load().isEmpty)
    }

    func testACorruptFileReadsAsAnEmptyLibraryInsteadOfThrowing() throws {
        try Data("not json".utf8).write(to: MiniAppIndex.storageURL)
        XCTAssertTrue(MiniAppIndex.load().isEmpty)
    }

    func testRoundTrip() {
        let entries = [
            MiniAppIndex.Entry(id: UUID(), name: "Einkaufsliste", symbol: "checklist"),
            MiniAppIndex.Entry(id: UUID(), name: "Timer", symbol: nil),
        ]
        XCTAssertTrue(MiniAppIndex.save(entries))
        XCTAssertEqual(MiniAppIndex.load(), entries)
    }

    func testSavingIdenticalContentReportsNoChange() {
        // The caller uses this to decide whether to re-index the Siri
        // vocabulary; a foreground that changed nothing must not trigger it.
        let entries = [MiniAppIndex.Entry(id: UUID(), name: "Timer", symbol: nil)]
        XCTAssertTrue(MiniAppIndex.save(entries))
        XCTAssertFalse(MiniAppIndex.save(entries))
    }

    func testTheSnapshotIsCappedSoThePickerStaysSmall() {
        let many = (0..<(MiniAppIndex.limit + 25)).map {
            MiniAppIndex.Entry(id: UUID(), name: "App \($0)", symbol: nil)
        }
        MiniAppIndex.save(many)
        XCTAssertEqual(MiniAppIndex.load().count, MiniAppIndex.limit)
        XCTAssertEqual(MiniAppIndex.load().first?.name, "App 0")
    }

    // MARK: entity query

    func testTheQueryOffersNothingWhenNothingIsSaved() async throws {
        let query = MiniAppEntityQuery()
        let suggested = try await query.suggestedEntities()
        let matched = try await query.entities(matching: "timer")
        let byId = try await query.entities(for: [UUID()])
        XCTAssertTrue(suggested.isEmpty)
        XCTAssertTrue(matched.isEmpty)
        XCTAssertTrue(byId.isEmpty)
    }

    func testTheQueryOffersSavedAppsAndMatchesThemByName() async throws {
        let timer = MiniAppIndex.Entry(id: UUID(), name: "Timer", symbol: "timer")
        let list = MiniAppIndex.Entry(id: UUID(), name: "Einkaufsliste", symbol: nil)
        MiniAppIndex.save([timer, list])

        let query = MiniAppEntityQuery()
        let suggested = try await query.suggestedEntities()
        let byPartialName = try await query.entities(matching: "einkauf")
        let byShoutedName = try await query.entities(matching: "TIMER")
        XCTAssertEqual(suggested.map(\.name), ["Timer", "Einkaufsliste"])
        XCTAssertEqual(byPartialName.map(\.id), [list.id])
        XCTAssertEqual(byShoutedName.map(\.id), [timer.id])
    }

    func testResolvingByIdIgnoresIdsThatAreNoLongerInTheLibrary() async throws {
        let timer = MiniAppIndex.Entry(id: UUID(), name: "Timer", symbol: "timer")
        MiniAppIndex.save([timer])
        let resolved = try await MiniAppEntityQuery().entities(for: [timer.id, UUID()])
        XCTAssertEqual(resolved.map(\.id), [timer.id])
    }

    func testAnUnnamedAppStillGetsAPickerLabel() async throws {
        // A blank row in the Shortcuts picker is unpickable; fall back to a
        // generic name rather than showing nothing.
        let blank = MiniAppIndex.Entry(id: UUID(), name: "", symbol: nil)
        MiniAppIndex.save([blank])
        let suggested = try await MiniAppEntityQuery().suggestedEntities()
        let entity = try XCTUnwrap(suggested.first)
        XCTAssertFalse(entity.name.isEmpty)
    }
}

// MARK: - The agent entity query

final class AgentEntityQueryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AgentStore.fileURLOverrideForTesting = directory.appendingPathComponent("agents.json")
    }

    override func tearDownWithError() throws {
        AgentStore.fileURLOverrideForTesting = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func writeRoster(_ agents: [AgentDefinition]) throws {
        let url = try XCTUnwrap(AgentStore.fileURLOverrideForTesting)
        try JSONEncoder().encode(agents).write(to: url)
    }

    func testNoAgentsMeansNoSuggestions() async throws {
        let suggested = try await AgentEntityQuery().suggestedEntities()
        XCTAssertTrue(suggested.isEmpty)
    }

    func testOnlyEnabledAgentsAreOffered() async throws {
        // A switched-off agent is not allowed to speak in a conversation, so
        // offering it in Siri would promise an answer that never arrives.
        let on = AgentDefinition(name: "Rechercheur", role: "recherchiert")
        var off = AgentDefinition(name: "Kritiker", role: "kritisiert")
        off.enabled = false
        try writeRoster([on, off])

        let offered = try await AgentEntityQuery().suggestedEntities()
        XCTAssertEqual(offered.map(\.name), ["Rechercheur"])
    }

    func testMatchingByNameSurvivesSiriTranscription() async throws {
        let translator = AgentDefinition(name: "Übersetzer", role: "übersetzt")
        try writeRoster([translator, AgentDefinition(name: "Planer", role: "plant")])

        let matched = try await AgentEntityQuery().entities(matching: "ubersetzer")
        XCTAssertEqual(matched.map(\.id), [translator.id])
    }

    func testResolvingByIdSkipsDeletedAgents() async throws {
        let planner = AgentDefinition(name: "Planer", role: "plant")
        try writeRoster([planner])
        let resolved = try await AgentEntityQuery().entities(for: [planner.id, UUID()])
        XCTAssertEqual(resolved.map(\.id), [planner.id])
    }

    func testTheEntityCarriesTheRoleAsItsSubtitle() async throws {
        let planner = AgentDefinition(name: "Planer", role: "zerlegt ein Ziel in Schritte")
        try writeRoster([planner])
        let suggested = try await AgentEntityQuery().suggestedEntities()
        let entity = try XCTUnwrap(suggested.first)
        XCTAssertEqual(entity.role, "zerlegt ein Ziel in Schritte")
    }
}

// MARK: - The router

@MainActor
final class IntentRouterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IntentRouter.shared.resetForTesting()
    }

    override func tearDown() {
        IntentRouter.shared.resetForTesting()
        super.tearDown()
    }

    func testConsumingClearsTheRequest() {
        IntentRouter.shared.request(.newChat(prompt: "hallo"))
        XCTAssertEqual(IntentRouter.shared.consumeRoute(), .newChat(prompt: "hallo"))
        XCTAssertNil(IntentRouter.shared.consumeRoute())
        XCTAssertNil(IntentRouter.shared.pending)
    }

    func testTheSameRouteTwiceRoutesTwice() {
        // Without the sequence number the second "neuer Chat" compares equal to
        // the first and SwiftUI's onChange never fires.
        IntentRouter.shared.request(.newChat(prompt: ""))
        let first = IntentRouter.shared.pending?.sequence
        _ = IntentRouter.shared.consumeRoute()
        IntentRouter.shared.request(.newChat(prompt: ""))
        XCTAssertNotEqual(first, IntentRouter.shared.pending?.sequence)
    }

    func testBlankStagedTextIsNotHandedToTheComposer() {
        IntentRouter.shared.stagedComposerText = "   \n "
        XCTAssertNil(IntentRouter.shared.takeStagedText())
        IntentRouter.shared.stagedComposerText = "Was ist ein Vektorprodukt?"
        XCTAssertEqual(IntentRouter.shared.takeStagedText(), "Was ist ein Vektorprodukt?")
        XCTAssertNil(IntentRouter.shared.takeStagedText())
    }
}

// MARK: - perform()

/// Counts every request that reaches the URL loading system, without changing
/// what happens to it (`canInit` returns false, so the normal handlers still
/// run). Registered globally for the duration of the test.
private final class RequestCounter: URLProtocol {
    nonisolated(unsafe) static var count = 0
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        count += 1
        lock.unlock()
        return false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

@MainActor
final class AiityIntentPerformTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IntentRouter.shared.resetForTesting()
        RequestCounter.count = 0
        URLProtocol.registerClass(RequestCounter.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(RequestCounter.self)
        IntentRouter.shared.resetForTesting()
        super.tearDown()
    }

    func testStartingAChatOnlyStagesTheText() async throws {
        _ = try await StartChatIntent(prompt: "Fasse meinen Tag zusammen").perform()
        XCTAssertEqual(
            IntentRouter.shared.consumeRoute(),
            .newChat(prompt: "Fasse meinen Tag zusammen")
        )
    }

    func testStartingAChatWithoutAPromptIsAllowed() async throws {
        // The parameter is optional and carries no `requestValueDialog`, so
        // "neuer Chat" must not turn into an interrogation.
        _ = try await StartChatIntent(prompt: nil).perform()
        XCTAssertEqual(IntentRouter.shared.consumeRoute(), .newChat(prompt: ""))
    }

    func testOpeningAMiniAppRoutesByIdentity() async throws {
        let id = UUID()
        let entity = MiniAppEntity(MiniAppIndex.Entry(id: id, name: "Timer", symbol: nil))
        _ = try await OpenMiniAppIntent(app: entity).perform()
        XCTAssertEqual(IntentRouter.shared.consumeRoute(), .openMiniApp(id: id))
    }

    func testAskingAnAgentRoutesTheAgentAndTheQuestion() async throws {
        let agent = AgentDefinition(name: "Rechercheur", role: "recherchiert")
        _ = try await AskAgentIntent(
            agent: AgentEntity(agent),
            question: "Wer hat den Bundestag 2021 gewonnen?"
        ).perform()
        XCTAssertEqual(
            IntentRouter.shared.consumeRoute(),
            .askAgent(id: agent.id, question: "Wer hat den Bundestag 2021 gewonnen?")
        )
    }

    /// The contract: a Shortcut can never spend provider tokens on its own.
    /// Every intent hands the text to the composer and stops — the user presses
    /// send. Counting URL loads is the direct evidence; it covers
    /// `URLSession.shared` and any default-configured session, which is every
    /// path a provider in this app uses.
    func testNoIntentStartsAModelRequest() async throws {
        _ = try await StartChatIntent(prompt: "kostet das Geld?").perform()
        _ = try await OpenMiniAppIntent(
            app: MiniAppEntity(MiniAppIndex.Entry(id: UUID(), name: "Timer", symbol: nil))
        ).perform()
        _ = try await AskAgentIntent(
            agent: AgentEntity(AgentDefinition(name: "Planer", role: "plant")),
            question: "und hier?"
        ).perform()

        XCTAssertEqual(
            RequestCounter.count, 0,
            "an App Intent fired a network request — a Shortcut must never spend tokens without the user seeing the text and pressing send"
        )
    }

    /// `perform()` deliberately does NOT touch `ChatSession`: on a cold launch
    /// there is no session yet. Anything it did there would either crash or
    /// silently do nothing, which is why the router exists.
    func testPerformDoesNotDisturbALiveSession() async throws {
        let session = ChatSession()
        let before = session.messages.count
        _ = try await StartChatIntent(prompt: "hallo").perform()
        XCTAssertEqual(session.messages.count, before)
        XCTAssertFalse(session.busy)
    }
}

// MARK: - Shortcut registration

final class AiityAppShortcutsTests: XCTestCase {
    /// `AppShortcut` does not expose its phrases at runtime, so a test cannot
    /// read them back — the real proof that the phrases are well formed is the
    /// build's `ExtractAppIntentsMetadata` step and the resulting
    /// `AIApp.app/Metadata.appintents/`. What IS checkable here is that the
    /// provider still offers exactly the three curated shortcuts: the result
    /// builder silently accepts a body that produces fewer, and a shortcut that
    /// quietly disappears is the failure this whole feature is prone to.
    func testTheProviderStillOffersTheThreeCuratedShortcuts() {
        XCTAssertEqual(AiityAppShortcuts.appShortcuts.count, 3)
    }
}
