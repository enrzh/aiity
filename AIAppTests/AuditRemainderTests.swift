import XCTest
@testable import AIApp

/// Regressions for the ten findings that survived refutation but were not
/// blockers. Written from the user-visible failure, as before.

/// An agent's model choice has to land in the field its dialect reads.
final class AgentModelRoutingTests: XCTestCase {

    /// `makeProvider` dispatches `.mlx` to `MLXProvider(modelId: localModelId)`
    /// and never reads `model`. Writing the agent's pick into `model` left
    /// `localModelId` holding whatever was selected globally, so a group with
    /// two agents on two different local models silently ran both on one —
    /// while the UI showed two.
    func testAnAgentsLocalModelReachesTheProvider() {
        var chat = ProviderSettings()
        chat.presetId = "mlx"
        chat.localModelId = "global/model"

        let agent = AgentDefinition(
            name: "Kritiker", role: "", emoji: "🧐", model: "mlx-community/Qwen3-1.7B-4bit"
        )
        let resolved = agent.settings(fallback: chat)

        XCTAssertEqual(resolved.localModelId, "mlx-community/Qwen3-1.7B-4bit")
        guard let provider = resolved.makeProvider(apiKey: "") as? MLXProvider else {
            return XCTFail("mlx must build an MLXProvider")
        }
        XCTAssertEqual(provider.modelId, "mlx-community/Qwen3-1.7B-4bit")
    }

    /// Cloud dialects are unchanged — the pick still belongs in `model`.
    func testACloudAgentsModelStillGoesToModel() {
        var chat = ProviderSettings()
        chat.presetId = "anthropic"
        let agent = AgentDefinition(name: "X", role: "", emoji: "🤖", model: "claude-sonnet-4-5")
        let resolved = agent.settings(fallback: chat)
        XCTAssertEqual(resolved.model, "claude-sonnet-4-5")
        XCTAssertEqual(resolved.effectiveModel, "claude-sonnet-4-5")
    }

    /// Two agents, two models — the property the whole feature rests on.
    func testTwoAgentsCanRunDifferentLocalModels() {
        var chat = ProviderSettings()
        chat.presetId = "mlx"
        chat.localModelId = "global/model"

        let small = AgentDefinition(name: "A", role: "", emoji: "🔎", model: "vendor/small")
        let large = AgentDefinition(name: "B", role: "", emoji: "⭐️", model: "vendor/large")
        XCTAssertNotEqual(
            small.settings(fallback: chat).localModelId,
            large.settings(fallback: chat).localModelId
        )
    }
}

/// The local transcript window in a group round.
final class LocalWindowUserMessageTests: XCTestCase {

    private func mlx() -> ProviderSettings {
        var s = ProviderSettings()
        s.presetId = "mlx"
        s.localModelId = "vendor/model"
        return s
    }

    /// By the time the lead speaks, the newest message is a PEER's turn, not
    /// the question. "Always keep the newest" therefore handed the lead one
    /// contribution and dropped both the user's question and the other agent's
    /// turn — while its brief told it to deliver what the user asked for.
    func testTheUsersQuestionSurvivesEvenBehindTwoLongTurns() {
        let long = String(repeating: "x", count: 3_500)
        let transcript = [
            ChatMessage(role: .user, text: "Bau mir einen Timer"),
            ChatMessage(role: .assistant, text: long, authorName: "Rechercheur"),
            ChatMessage(role: .assistant, text: long, authorName: "Kritiker"),
        ]
        let window = LocalRuntimePolicy.transcriptWindow(transcript, for: mlx(), cloudLimit: 40)

        XCTAssertTrue(
            window.contains { $0.role == .user && $0.text == "Bau mir einen Timer" },
            "the lead cannot deliver what it can no longer see"
        )
    }

    /// One fenced mini-app turn is up to 60 000 characters — ten times the
    /// budget — and used to become the lead's entire input.
    func testAnOversizedPeerTurnCannotEvictTheQuestion() {
        let huge = "```html\n" + String(repeating: "y", count: 60_000) + "\n```"
        let transcript = [
            ChatMessage(role: .user, text: "Frage"),
            ChatMessage(role: .assistant, text: huge, authorName: "Rechercheur"),
        ]
        let window = LocalRuntimePolicy.transcriptWindow(transcript, for: mlx(), cloudLimit: 40)
        XCTAssertTrue(window.contains { $0.text == "Frage" })
    }

    func testTheWindowIsStillChronological() {
        let transcript = (0..<20).map { ChatMessage(role: .user, text: "m\($0)") }
        let window = LocalRuntimePolicy.transcriptWindow(transcript, for: mlx(), cloudLimit: 40)
        XCTAssertEqual(window.map(\.text), window.map(\.text).sorted {
            Int($0.dropFirst())! < Int($1.dropFirst())!
        })
    }

    func testATranscriptWithNoUserMessageStillReturnsSomething() {
        let transcript = [ChatMessage(role: .assistant, text: "nur ein Beitrag", authorName: "A")]
        XCTAssertEqual(
            LocalRuntimePolicy.transcriptWindow(transcript, for: mlx(), cloudLimit: 40).count, 1
        )
    }
}

/// SSRF: the guards read a string, and a string can lie.
final class HostResolutionTests: XCTestCase {

    /// A public NAME that resolves to a private address passed every check,
    /// because nothing resolved it. `192.168.178.1.nip.io` is the canonical
    /// example and needs no attacker infrastructure.
    func testALiteralPrivateAddressIsStillBlocked() {
        XCTAssertTrue(FetchURLTool.isBlockedHost("192.168.178.1"))
        XCTAssertTrue(FetchURLTool.isBlockedHost("127.0.0.1"))
        XCTAssertTrue(FetchURLTool.isBlockedHost("[::1]"))
        XCTAssertTrue(FetchURLTool.isBlockedHost("169.254.169.254"))
    }

    /// The resolver path itself: a name that maps to loopback must be refused.
    /// `localhost` is guaranteed to resolve on any machine, so this exercises
    /// resolution without depending on a third-party DNS service.
    func testANameResolvingToLoopbackIsRefused() {
        XCTAssertTrue(FetchURLTool.resolvesToPrivateAddress("localhost"))
    }

    /// Failing closed on every DNS hiccup would break ordinary fetches, so an
    /// unresolvable name is not treated as private.
    func testAnUnresolvableNameIsNotTreatedAsPrivate() {
        XCTAssertFalse(
            FetchURLTool.resolvesToPrivateAddress("this-name-does-not-exist.aiity-test.invalid")
        )
    }
}

/// The diagnostics signal path must not allocate.
final class SignalPathTests: XCTestCase {

    /// Not directly observable from a test — the property is "no malloc" — but
    /// the format the two sides agree on is, and a rewrite that breaks it
    /// breaks crash recovery silently.
    func testTheMarkerFormatSurvivesTheAllocationFreeRewrite() throws {
        let fatal = try XCTUnwrap(
            DiagnosticsRecorder.parseSignalMarker("sig 11\nf 0x1044e2a10\nf 0xdeadbeef\n", at: Date())
        )
        XCTAssertEqual(fatal.name, "SIGSEGV")
        XCTAssertEqual(fatal.frames, ["0x1044e2a10", "0xdeadbeef"])
    }

    /// Signal numbers are written digit by digit into a fixed buffer; a
    /// two-digit and a one-digit value must both round-trip.
    func testBothSingleAndMultiDigitSignalsParse() throws {
        for (number, name) in [(6, "SIGABRT"), (11, "SIGSEGV"), (4, "SIGILL")] {
            let fatal = try XCTUnwrap(
                DiagnosticsRecorder.parseSignalMarker("sig \(number)\n", at: Date())
            )
            XCTAssertEqual(fatal.name, name)
        }
    }
}

/// A system crash report must belong to the run it is printed under.
final class MetricKitRetirementTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metrickit-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The payload was written once and never removed, so a report four
    /// launches later said "sauber beendet" for the last run and, directly
    /// below, printed an older crash's stack as if it belonged to it.
    func testAnOldPayloadIsNotAttachedToALaterCleanRun() throws {
        // Launch A crashes and iOS delivers a payload.
        let first = DiagnosticsRecorder(directory: directory)
        first.record("app", "Arbeit")
        try Data(#"{"crashDiagnostics":[{"diagnosticMetaData":{"signal":11}}]}"#.utf8)
            .write(to: directory.appendingPathComponent("metrickit-latest.json"))

        // Launch B folds it in — this run legitimately carries the report.
        let second = DiagnosticsRecorder(directory: directory)
        XCTAssertNotNil(second.lastRunSnapshot().metricKit)
        second.markCleanExit(reason: "terminate")

        // Launch C: the previous run ended cleanly and no new payload arrived.
        let third = DiagnosticsRecorder(directory: directory)
        let snapshot = third.lastRunSnapshot()
        XCTAssertEqual(snapshot.verdict, .clean)
        XCTAssertNil(
            snapshot.metricKit,
            "a clean run must not carry a previous crash's system report"
        )
    }
}

/// The mini-app sandbox must refuse LAN targets on every hop, not just the first.
final class BrowserTierTargetTests: XCTestCase {

    func testPrivateTargetsAreRefused() {
        for raw in [
            "http://192.168.178.1/",
            "http://127.0.0.1:11434/api/tags",
            "http://169.254.169.254/latest/meta-data/",
            "http://10.0.0.1/",
        ] {
            let url = URL(string: raw)!
            XCTAssertFalse(
                NetworkTargetValidator.isAllowed(url, allowPrivate: false),
                "\(raw) must not be reachable from a mini-app"
            )
        }
    }

    func testOrdinarySitesStillLoad() {
        for raw in ["https://example.com/", "https://news.ycombinator.com/"] {
            XCTAssertTrue(NetworkTargetValidator.isAllowed(URL(string: raw)!, allowPrivate: false), raw)
        }
    }

    /// Refusing the target used to fall through to rendering the generated
    /// shell — which contains `location.replace(<target>)` for the very URL
    /// just refused, performing the navigation anyway.
    func testTheRefusalPlaceholderDoesNotCarryTheTarget() {
        let refused = MiniAppRunnerView.refusedHTML(URL(string: "http://192.168.178.1/")!)
        XCTAssertFalse(refused.contains("location.replace"))
        XCTAssertFalse(refused.contains("http://192.168.178.1/"))
        XCTAssertTrue(refused.contains("192.168.178.1"), "it should still say what was blocked")
    }
}
