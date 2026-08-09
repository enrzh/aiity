import XCTest
@testable import AIApp

// MARK: - Shared fixtures

private func makePendingTurn(
    threadId: UUID = UUID(),
    userText: String = "bau mir eine Todo-App",
    turnStartIndex: Int = 1,
    repairPasses: Int = 0,
    startedAt: Date,
    updatedAt: Date? = nil,
    partial: String = ""
) -> PendingTurn {
    PendingTurn(
        threadId: threadId,
        userText: userText,
        turnStartIndex: turnStartIndex,
        repairPasses: repairPasses,
        startedAt: startedAt,
        updatedAt: updatedAt ?? startedAt,
        partialAssistantText: partial
    )
}

// MARK: - The stop-vs-resume ordering contract

/// The single most likely cross-feature bug: the Live Activity's Stop button
/// persists a request for the suspended/terminated case, and the interrupted
/// turn wants to be replayed on the next foreground. If the resume path looked
/// at its checkpoint first, a run the user explicitly cancelled from the Lock
/// Screen would come back to life. STOP BEATS RESUME — both directions pinned
/// here.
final class TurnRestorePolicyTests: XCTestCase {

    func testAStopRequestedAfterTheTurnBeganDiscardsTheCheckpoint() {
        let started = Date(timeIntervalSince1970: 1_000)
        let pending = makePendingTurn(startedAt: started, updatedAt: started.addingTimeInterval(20))
        let decision = TurnRestorePolicy.decide(
            stopRequestedAt: started.addingTimeInterval(10),
            pending: pending,
            now: started.addingTimeInterval(30)
        )
        XCTAssertEqual(decision, .discardCancelledTurn,
                       "a turn cancelled from the Lock Screen must never be replayed")
    }

    func testAStopRequestWithoutACheckpointStillAsksForCleanup() {
        // App was terminated before it could write a checkpoint; the persisted
        // flag still has to reach the thread repair on the next cold launch.
        let decision = TurnRestorePolicy.decide(
            stopRequestedAt: Date(timeIntervalSince1970: 1_000),
            pending: nil,
            now: Date(timeIntervalSince1970: 1_050)
        )
        XCTAssertEqual(decision, .discardCancelledTurn)
    }

    func testALeftoverStopFlagFromAnEarlierTurnDoesNotEatTheNewOne() {
        // Defensive: send() also clears the flag, so this should not arise —
        // but eating a legitimate resume silently is the worse failure.
        let started = Date(timeIntervalSince1970: 2_000)
        let pending = makePendingTurn(startedAt: started, updatedAt: started.addingTimeInterval(5))
        let decision = TurnRestorePolicy.decide(
            stopRequestedAt: started.addingTimeInterval(-60),
            pending: pending,
            now: started.addingTimeInterval(10)
        )
        XCTAssertEqual(decision, .offerResume(pending))
    }

    func testAFreshCheckpointIsOfferedForResume() {
        let now = Date(timeIntervalSince1970: 5_000)
        let pending = makePendingTurn(startedAt: now.addingTimeInterval(-30))
        XCTAssertEqual(
            TurnRestorePolicy.decide(stopRequestedAt: nil, pending: pending, now: now),
            .offerResume(pending)
        )
    }

    func testAnAncientCheckpointIsDroppedRatherThanOffered() {
        let now = Date(timeIntervalSince1970: 90_000)
        let pending = makePendingTurn(
            startedAt: now.addingTimeInterval(-TurnRestorePolicy.resumeOfferWindow - 60)
        )
        XCTAssertEqual(
            TurnRestorePolicy.decide(stopRequestedAt: nil, pending: pending, now: now),
            .none
        )
    }

    func testNothingPendingIsNothingToDo() {
        XCTAssertEqual(TurnRestorePolicy.decide(stopRequestedAt: nil, pending: nil), .none)
    }
}

// MARK: - Checkpoint persistence

final class PendingTurnStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-turn-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PendingTurnStore.directoryOverride = directory
    }

    override func tearDown() {
        PendingTurnStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testCheckpointSurvivesARoundTrip() {
        let turn = makePendingTurn(
            turnStartIndex: 7,
            repairPasses: 1,
            startedAt: Date(timeIntervalSince1970: 10_000),
            updatedAt: Date(timeIntervalSince1970: 10_042),
            partial: "<!doctype html><title>Todo"
        )
        PendingTurnStore.save(turn)
        XCTAssertEqual(PendingTurnStore.load(), turn)
    }

    func testClearRemovesTheCheckpoint() {
        PendingTurnStore.save(makePendingTurn(startedAt: Date()))
        XCTAssertNotNil(PendingTurnStore.load())
        PendingTurnStore.clear()
        XCTAssertNil(PendingTurnStore.load())
    }

    func testPartialTextIsCappedSoTheWriteFitsInTheExpirationGrace() {
        // A streamed mini-app is hundreds of KB; the checkpoint must not be.
        let huge = String(repeating: "x", count: PendingTurn.maxPartialChars * 3)
        PendingTurnStore.save(makePendingTurn(startedAt: Date(), partial: huge))
        let loaded = PendingTurnStore.load()
        XCTAssertEqual(loaded?.partialAssistantText.count, PendingTurn.maxPartialChars)
    }

    func testAMissingFileIsSimplyNoCheckpoint() {
        XCTAssertNil(PendingTurnStore.load())
    }
}

// MARK: - Suspension vs. a real network fault

final class TurnInterruptionPolicyTests: XCTestCase {

    func testAFrozenSocketWhileBackgroundedIsAPauseNotAnError() {
        XCTAssertTrue(TurnInterruptionPolicy.isBackgroundInterruption(
            error: URLError(.networkConnectionLost), wasBackgrounded: true
        ))
        XCTAssertTrue(TurnInterruptionPolicy.isBackgroundInterruption(
            error: URLError(.timedOut), wasBackgrounded: true
        ))
    }

    func testTheSameErrorInTheForegroundStaysARealNetworkFault() {
        // Dressing a genuine outage up as "pausiert" would hide it.
        XCTAssertFalse(TurnInterruptionPolicy.isBackgroundInterruption(
            error: URLError(.networkConnectionLost), wasBackgrounded: false
        ))
    }

    func testANonNetworkFailureIsNeverAPause() {
        struct Boom: Error {}
        XCTAssertFalse(TurnInterruptionPolicy.isBackgroundInterruption(
            error: Boom(), wasBackgrounded: true
        ))
        XCTAssertFalse(TurnInterruptionPolicy.isBackgroundInterruption(
            error: URLError(.badServerResponse), wasBackgrounded: true
        ))
    }
}

// MARK: - Notification policy from a background path

/// Previously shipped policy that must not regress: no background code path
/// ever calls `requestAuthorization` — the system cannot present the dialog
/// there, the notification is lost, and the prompt resurfaces later without
/// context (Guideline 5.1.1). So "never asked" degrades to silence, not to a
/// prompt.
final class BackgroundNotificationPolicyTests: XCTestCase {

    func testAnAuthorizedUserGetsThePauseAlert() {
        XCTAssertEqual(
            AgentBackgroundNotifier.plan(gate: .post, title: "T", body: "B"),
            .post(title: "T", body: "B")
        )
    }

    func testNeverAskedDegradesToSilenceInsteadOfRequestingAuthorization() {
        XCTAssertEqual(
            AgentBackgroundNotifier.plan(gate: .ask, title: "T", body: "B"),
            .skip(.ask),
            "a background path must not open the permission dialog"
        )
    }

    func testADeclinedUserIsNeverRePrompted() {
        XCTAssertEqual(
            AgentBackgroundNotifier.plan(gate: .refuse, title: "T", body: "B"),
            .skip(.refuse)
        )
    }

    func testPostingIsSkippedEndToEndWhenAuthorizationWasNeverGranted() async {
        var posted: [(String, String)] = []
        AgentBackgroundNotifier.gateOverride = .ask
        AgentBackgroundNotifier.sinkForTesting = { posted.append(($0, $1)) }
        defer {
            AgentBackgroundNotifier.gateOverride = nil
            AgentBackgroundNotifier.sinkForTesting = nil
        }
        let action = await AgentBackgroundNotifier.postTurnPaused()
        XCTAssertEqual(action, .skip(.ask))
        XCTAssertTrue(posted.isEmpty)
    }

    func testPostingHappensWhenAuthorizationExists() async {
        var posted: [(String, String)] = []
        AgentBackgroundNotifier.gateOverride = .post
        AgentBackgroundNotifier.sinkForTesting = { posted.append(($0, $1)) }
        defer {
            AgentBackgroundNotifier.gateOverride = nil
            AgentBackgroundNotifier.sinkForTesting = nil
        }
        _ = await AgentBackgroundNotifier.postTurnPaused()
        XCTAssertEqual(posted.count, 1)
        XCTAssertFalse(posted[0].0.isEmpty)
    }
}

// MARK: - The Live Activity Stop button

/// Driving a Lock Screen / Dynamic Island button from a test is not possible,
/// so the intent's `perform()` — the code the system actually runs, in the APP
/// process — is exercised directly instead.
final class StopAgentRunIntentTests: XCTestCase {
    private var suite: UserDefaults!
    private let suiteName = "aiity.tests.stoprequest"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        AgentRunStopRequest.store = suite
    }

    override func tearDown() {
        AgentRunStopRequest.store = .standard
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPerformPersistsTheRequestBeforeSignallingTheApp() async throws {
        XCTAssertNil(AgentRunStopRequest.pendingDate())
        // Read the flag INSIDE the observer, which NotificationCenter runs
        // synchronously during the post. Checking afterwards would be racy for
        // a real reason: the test host runs a live ChatSession, which observes
        // this notification and — correctly — consumes the flag.
        var flagWhenSignalled: Date?
        let signalled = expectation(description: "app signalled")
        let token = NotificationCenter.default.addObserver(
            forName: .aiityAgentStopRequested, object: nil, queue: nil
        ) { _ in
            flagWhenSignalled = AgentRunStopRequest.pendingDate()
            signalled.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try await StopAgentRunIntent().perform()

        await fulfillment(of: [signalled], timeout: 3)
        XCTAssertNotNil(
            flagWhenSignalled,
            "the flag must already be written when the app is signalled — it is what covers the suspended / terminated process, where no ChatSession hears the notification"
        )
    }

    func testOnlyAnExplicitClearConsumesTheStopRequest() throws {
        // The intent must never clear its own flag, or the cold-launch cleanup
        // after a terminated-process stop never runs.
        let stamp = Date(timeIntervalSince1970: 1_234_567)
        AgentRunStopRequest.record(at: stamp)
        let recorded = try XCTUnwrap(AgentRunStopRequest.pendingDate())
        XCTAssertEqual(recorded.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.001)
        AgentRunStopRequest.clear()
        XCTAssertNil(AgentRunStopRequest.pendingDate())
    }
}

// MARK: - Session-level wiring

@MainActor
final class ChatSessionBackgroundTurnTests: XCTestCase {
    private var directory: URL!
    private var suite: UserDefaults!
    private let suiteName = "aiity.tests.session.stoprequest"

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-pending-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PendingTurnStore.directoryOverride = directory
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        AgentRunStopRequest.store = suite
        BackgroundTurnGuard.disableSystemTaskForTesting = true
    }

    override func tearDown() {
        BackgroundTurnGuard.disableSystemTaskForTesting = false
        AgentRunStopRequest.store = .standard
        suite.removePersistentDomain(forName: suiteName)
        PendingTurnStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A turn mid-tool-loop: an assistant `tool_use` with no matching result.
    private func startedTurn(on session: ChatSession) {
        session.messages = [
            ChatMessage(role: .user, text: "bau mir eine Todo-App"),
            ChatMessage(
                role: .assistant,
                text: "",
                toolCalls: [ToolCallData(id: "call-1", name: "web_search", argumentsJSON: "{}")]
            )
        ]
        session.beginTurnForTesting(userText: "bau mir eine Todo-App", turnStartIndex: 0)
    }

    // MARK: stop → no checkpoint

    func testStoppingDeletesTheResumeCheckpoint() {
        let session = ChatSession()
        startedTurn(on: session)
        session.checkpointPendingTurnForTesting()
        XCTAssertNotNil(PendingTurnStore.load(), "precondition: a checkpoint exists")

        session.stop()

        XCTAssertNil(PendingTurnStore.load(), "stop must leave nothing to replay")
        XCTAssertNil(session.interruptedTurn)
        XCTAssertNil(AgentRunStopRequest.pendingDate(), "the served request must not cancel the next turn")
        XCTAssertFalse(session.busy)
    }

    func testStopFromTheLiveActivityWithNothingRunningStillCleansTheThread() {
        let session = ChatSession()
        // The turn already died with the process; the flag is all that is left.
        session.messages = [
            ChatMessage(role: .user, text: "hallo"),
            ChatMessage(
                role: .assistant,
                text: "",
                toolCalls: [ToolCallData(id: "orphan", name: "web_search", argumentsJSON: "{}")]
            )
        ]
        AgentRunStopRequest.record()
        PendingTurnStore.save(makePendingTurn(startedAt: Date()))

        session.stopFromLiveActivity()

        XCTAssertNil(PendingTurnStore.load())
        XCTAssertNil(AgentRunStopRequest.pendingDate())
        XCTAssertFalse(
            session.messages.contains { !$0.toolCalls.isEmpty },
            "an orphaned tool_use breaks the Anthropic thread forever"
        )
    }

    // MARK: foreground → stop beats resume

    func testForegroundAfterALockScreenStopNeverReplaysTheTurn() {
        let session = ChatSession()
        let started = Date().addingTimeInterval(-30)
        PendingTurnStore.save(makePendingTurn(
            threadId: session.activeThreadIdForTesting,
            startedAt: started
        ))
        // The user tapped Stop AFTER the turn began — the real ordering.
        AgentRunStopRequest.record(at: started.addingTimeInterval(10))

        session.handleAppForeground()

        XCTAssertNil(session.interruptedTurn, "a cancelled turn must not be offered for resume")
        XCTAssertNil(PendingTurnStore.load())
        XCTAssertNil(AgentRunStopRequest.pendingDate())
    }

    func testForegroundOffersResumeWhenNoStopWasRequested() {
        let session = ChatSession()
        let pending = makePendingTurn(
            threadId: session.activeThreadIdForTesting,
            startedAt: Date().addingTimeInterval(-30)
        )
        PendingTurnStore.save(pending)

        session.handleAppForeground()

        XCTAssertEqual(session.interruptedTurn, pending)
    }

    func testARunningTurnIsNeverOfferedAsAnInterruptionOnAQuickAppSwitch() {
        let session = ChatSession()
        startedTurn(on: session)
        session.checkpointPendingTurnForTesting()

        session.handleAppForeground()

        XCTAssertNil(session.interruptedTurn, "it is still running — there is nothing to resume")
        XCTAssertNotNil(PendingTurnStore.load(), "and its live checkpoint must survive")
    }

    // MARK: the expiration handler

    func testExpirationCheckpointsThenNotifiesThenCancelsThenRepairs() {
        let session = ChatSession()
        startedTurn(on: session)

        session.handleBackgroundTimeExpiring()

        XCTAssertEqual(
            session.expirationSteps,
            ["checkpoint", "notify", "cancel", "repair", "liveActivityPaused"],
            "checkpointing FIRST is the point — everything after it may be cut short"
        )
        XCTAssertNotNil(PendingTurnStore.load(), "the turn must be resumable")
        XCTAssertFalse(session.busy)
        XCTAssertNil(session.statusLine)
        XCTAssertFalse(
            session.messages.contains { !$0.toolCalls.isEmpty },
            "dangling tool_use must be dropped before the process is suspended"
        )
        XCTAssertNotNil(session.interruptedTurn)
        XCTAssertNil(session.errorMessage, "a pause is not a failure")
    }

    func testExpirationDoesNothingWhenNoTurnIsRunning() {
        let session = ChatSession()
        session.handleBackgroundTimeExpiring()
        XCTAssertTrue(session.expirationSteps.isEmpty)
        XCTAssertNil(PendingTurnStore.load())
    }

    func testStoppingAPausedTurnDiscardsItsCheckpoint() {
        // The Stop button still renders on the "Pausiert" card, and pressing
        // it there must mean the same thing it means everywhere else.
        let session = ChatSession()
        startedTurn(on: session)
        session.handleBackgroundTimeExpiring()
        XCTAssertNotNil(session.interruptedTurn)

        session.stopFromLiveActivity()

        XCTAssertNil(session.interruptedTurn)
        XCTAssertNil(PendingTurnStore.load())
    }

    // MARK: replay

    func testResumeRewindsToTheStartOfTheInterruptedTurn() {
        let session = ChatSession()
        session.messages = [
            ChatMessage(role: .system, text: "system"),
            ChatMessage(role: .user, text: "bau mir eine Todo-App"),
            ChatMessage(
                role: .assistant,
                text: "halbe Antwort",
                toolCalls: [ToolCallData(id: "call-9", name: "web_search", argumentsJSON: "{}")]
            )
        ]
        let pending = makePendingTurn(
            threadId: session.activeThreadIdForTesting,
            turnStartIndex: 1,
            startedAt: Date()
        )

        let text = session.rewindToInterruptedTurnStart(pending)

        XCTAssertEqual(text, "bau mir eine Todo-App", "the replay re-sends the same message")
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages.first?.role, .system)
    }

    func testAStaleCheckpointIndexIsRefusedRatherThanTrapping() {
        let session = ChatSession()
        session.messages = [ChatMessage(role: .user, text: "kurz")]
        let pending = makePendingTurn(
            threadId: session.activeThreadIdForTesting,
            turnStartIndex: 99,
            startedAt: Date()
        )
        XCTAssertNil(session.rewindToInterruptedTurnStart(pending))
    }

    func testDismissingTheOfferRemovesTheCheckpoint() {
        let session = ChatSession()
        PendingTurnStore.save(makePendingTurn(
            threadId: session.activeThreadIdForTesting,
            startedAt: Date()
        ))
        session.handleAppForeground()
        XCTAssertNotNil(session.interruptedTurn)

        session.dismissInterruptedTurn()

        XCTAssertNil(session.interruptedTurn)
        XCTAssertNil(PendingTurnStore.load())
    }
}
