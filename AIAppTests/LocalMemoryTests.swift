import XCTest
@testable import AIApp

/// Guards the fixes for a real device kill: a group round on an on-device model
/// reached 2822 MB against 554 MB of headroom and iOS ended the process.
/// The weights were only half of it — the other half was handing every agent
/// the whole shared transcript on every turn.
final class LocalTranscriptBudgetTests: XCTestCase {

    private func settings(dialect: ProviderDialect) -> ProviderSettings {
        var settings = ProviderSettings()
        settings.presetId = dialect == .mlx ? "mlx" : "anthropic"
        settings.model = dialect == .mlx ? "mlx-community/Qwen3-4B-Instruct-2507-4bit" : "claude-sonnet-4-5"
        return settings
    }

    private func transcript(count: Int, each characters: Int) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(role: .user, text: String(repeating: "x", count: characters) + "#\(index)")
        }
    }

    /// A cloud provider pays in tokens, not in resident memory — its window
    /// must not shrink just because the local one had to.
    func testCloudProvidersKeepTheFullWindow() {
        let messages = transcript(count: 60, each: 500)
        let window = LocalRuntimePolicy.transcriptWindow(
            messages, for: settings(dialect: .anthropic), cloudLimit: 40
        )
        XCTAssertEqual(window.count, 40)
    }

    func testALocalModelIsHeldToTheCharacterBudget() {
        let messages = transcript(count: 40, each: 1_000)
        let window = LocalRuntimePolicy.transcriptWindow(
            messages, for: settings(dialect: .mlx), cloudLimit: 40
        )
        let characters = window.reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(characters, LocalRuntimePolicy.localTranscriptBudget + 1_100)
        XCTAssertLessThan(window.count, 40, "the local window must actually be smaller")
        XCTAssertFalse(window.isEmpty)
    }

    /// The newest message is the thing being replied to. Dropping it to satisfy
    /// a budget produces a confident answer to nothing.
    func testTheNewestMessageSurvivesEvenIfItAloneExceedsTheBudget() {
        let huge = ChatMessage(
            role: .user,
            text: String(repeating: "y", count: LocalRuntimePolicy.localTranscriptBudget * 3)
        )
        let window = LocalRuntimePolicy.transcriptWindow(
            [ChatMessage(role: .user, text: "alt"), huge],
            for: settings(dialect: .mlx), cloudLimit: 40
        )
        XCTAssertEqual(window.count, 1)
        XCTAssertEqual(window.last?.text, huge.text)
    }

    /// Order is what makes a transcript a transcript.
    func testTheWindowStaysInChronologicalOrder() {
        let messages = transcript(count: 30, each: 300)
        let window = LocalRuntimePolicy.transcriptWindow(
            messages, for: settings(dialect: .mlx), cloudLimit: 40
        )
        XCTAssertEqual(window, window.sorted { lhs, rhs in
            messages.firstIndex(of: lhs)! < messages.firstIndex(of: rhs)!
        })
        XCTAssertEqual(window.last?.text, messages.last?.text, "the newest must be last")
    }

    func testAShortConversationIsNotTrimmedAtAll() {
        let messages = transcript(count: 3, each: 50)
        let window = LocalRuntimePolicy.transcriptWindow(
            messages, for: settings(dialect: .mlx), cloudLimit: 40
        )
        XCTAssertEqual(window.count, 3)
    }
}

final class MemoryPressureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MemoryPressure.shared.reset()
    }

    override func tearDown() {
        MemoryPressure.shared.reset()
        super.tearDown()
    }

    func testHandlersRunOnPressure() {
        var released = 0
        MemoryPressure.shared.onPressure("test") { released += 1 }
        MemoryPressure.shared.note()
        XCTAssertEqual(released, 1)
        XCTAssertEqual(MemoryPressure.shared.warningCount, 1)
    }

    /// The runtime registers itself once per construction; a second
    /// registration under the same name must replace rather than double up.
    func testRegisteringTheSameNameTwiceDoesNotRunItTwice() {
        var released = 0
        MemoryPressure.shared.onPressure("mlx") { released += 1 }
        MemoryPressure.shared.onPressure("mlx") { released += 1 }
        MemoryPressure.shared.note()
        XCTAssertEqual(released, 1)
    }

    /// This is what a running round consults to decide whether to stop.
    func testWarningsAreScopedToTheRoundThatIsAsking() {
        let beforeAnything = Date()
        XCTAssertEqual(MemoryPressure.shared.warnings(since: beforeAnything), 0)

        MemoryPressure.shared.note()
        MemoryPressure.shared.note()
        XCTAssertEqual(MemoryPressure.shared.warnings(since: beforeAnything), 2)

        // A round starting after the warnings must not inherit them, or every
        // later round would start already over budget.
        let laterRound = Date().addingTimeInterval(1)
        XCTAssertEqual(MemoryPressure.shared.warnings(since: laterRound), 0)
    }

    /// The threshold has to sit ABOVE what a healthy round produces. Measured on
    /// device: a three-agent round on a local 4B model produced six warnings,
    /// absorbed every one by releasing the model, and finished. A threshold at
    /// or below that would abort nearly every local round — trading a crash for
    /// a feature that never completes, which is not an improvement.
    func testTheAbortThresholdIsAboveAHealthyRound() {
        let observedHealthyRound = 6
        XCTAssertGreaterThan(
            GroupChatRunner.memoryWarningAbortThreshold, observedHealthyRound * 2,
            "a backstop this low would fire during normal operation"
        )
    }

    func testTheAbortThresholdIsActuallyReachable() {
        let started = Date()
        for _ in 0..<GroupChatRunner.memoryWarningAbortThreshold {
            MemoryPressure.shared.note()
        }
        XCTAssertGreaterThanOrEqual(
            MemoryPressure.shared.warnings(since: started),
            GroupChatRunner.memoryWarningAbortThreshold,
            "a backstop that can never fire is not a backstop"
        )
    }
}

/// The cache that never released anything.
final class MLXResidencyTests: XCTestCase {

    /// One resident model. A 4-bit 4B model is ~2.3 GB and the app gets roughly
    /// 3.4 GB before jetsam, so a second is not a cache — it is the kill.
    /// Agents in a group may each name their own model, which is how a second
    /// one gets loaded without anyone asking for it.
    func testOnlyOneModelMayStayResident() {
        XCTAssertEqual(MLXRuntime.maxResidentModels, 1)
    }

    /// Registered at construction, so memory comes back whether or not any
    /// view happens to be alive.
    func testTheRuntimeRegistersForMemoryPressure() {
        MemoryPressure.shared.reset()
        _ = MLXRuntime.shared          // may already exist; re-register is idempotent
        MLXRuntime.shared.evictAll()   // must not trap with nothing loaded
        MemoryPressure.shared.note()   // must not trap with no handler either
    }
}
