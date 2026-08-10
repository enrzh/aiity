import XCTest
@testable import AIApp

/// Regressions for the defects an adversarial audit confirmed before release.
/// Each one describes the user-visible failure, not the code shape — the code
/// shape is what changed.

/// The blocker: switching conversation mid-answer.
@MainActor
final class ThreadSwitchSafetyTests: XCTestCase {

    /// A solo turn holds a raw index into `messages` across the streaming
    /// await, and switching conversations replaces that array wholesale. The
    /// next token then either traps on an out-of-range index or writes this
    /// conversation's answer into the middle of the other one — and persists
    /// it. So a solo turn must not survive the switch.
    func testSwitchingConversationStopsARunningSoloTurn() {
        let session = ChatSession()
        guard let first = session.newThread() else { return XCTFail("no thread") }
        session.messages = [ChatMessage(role: .user, text: "läuft")]
        session.persistPublic()
        guard let second = session.newThread() else { return XCTFail("no second thread") }
        // Content matters: persist() prunes empty threads, so a fixture without
        // a message vanishes before the switch under test can find it.
        session.messages = [ChatMessage(role: .user, text: "andere Unterhaltung")]
        session.persistPublic()

        session.switchTo(threadId: first)
        XCTAssertEqual(session.activeThreadIdForTesting, first, "precondition: first is open")
        session.busy = true                 // stand in for a streaming solo turn
        XCTAssertNil(session.runningThreadId, "a solo turn sets no runningThreadId")

        session.switchTo(threadId: second)
        XCTAssertEqual(session.activeThreadIdForTesting, second, "the switch must happen")
        XCTAssertFalse(session.busy, "the unsafe turn must be stopped, not left running")
    }

    /// A GROUP round is safe across the switch — it captured its thread id and
    /// files every turn by id. Stopping it too would undo the feature the user
    /// asked for ("when I leave the chat and it's running, it should continue").
    func testSwitchingConversationLetsAGroupRoundKeepRunning() {
        let session = ChatSession()
        guard let group = session.newThread() else { return XCTFail("no thread") }
        session.messages = [ChatMessage(role: .user, text: "gruppe")]
        session.persistPublic()
        guard let other = session.newThread() else { return XCTFail("no second thread") }
        session.messages = [ChatMessage(role: .user, text: "andere Unterhaltung")]
        session.persistPublic()

        session.switchTo(threadId: group)
        session.beginGroupRoundForTesting(threadId: group)
        XCTAssertEqual(session.runningThreadId, group)

        session.switchTo(threadId: other)
        XCTAssertTrue(session.busy, "a thread-scoped group round must survive the switch")
        XCTAssertEqual(session.runningThreadId, group)
    }

    /// `stop()` cleared `busy` but not `runningThreadId`, so a stopped round
    /// left a permanent "läuft…" badge in the conversation list — and now that
    /// `switchTo` reads the flag to tell a safe round from an unsafe turn, a
    /// stale value would misclassify the next one.
    func testStopClearsTheRunningThreadMarker() {
        let session = ChatSession()
        guard let id = session.newThread() else { return XCTFail("no thread") }
        session.beginGroupRoundForTesting(threadId: id)
        XCTAssertNotNil(session.runningThreadId)

        session.stop()
        XCTAssertNil(session.runningThreadId)
        XCTAssertFalse(session.busy)
    }

    /// `newThread()` declines while a turn is running and returns nil. Ignoring
    /// that and assigning `messages` replaced the LIVE conversation — the user
    /// tapped "Mit KI bearbeiten" on a mini-app and lost the chat they were in.
    func testEditingAMiniAppRefusesToClobberARunningConversation() {
        let session = ChatSession()
        guard session.newThread() != nil else { return XCTFail("no thread") }
        session.messages = [
            ChatMessage(role: .user, text: "wichtig"),
            ChatMessage(role: .assistant, text: "läuft gerade"),
        ]
        session.busy = true

        session.startEditing(id: UUID(), name: "Timer", html: "<html></html>")

        XCTAssertEqual(session.messages.count, 2, "the running conversation must be untouched")
        XCTAssertEqual(session.messages.first?.text, "wichtig")
        XCTAssertNotNil(session.errorMessage, "refusing silently looks like a broken button")
    }
}

/// The other blocker: a request window that deleted stored history.
@MainActor
final class LocalHistoryWindowTests: XCTestCase {

    private func longHistory() -> [ChatMessage] {
        [ChatMessage(role: .system, text: "system")]
            + (0..<40).map { ChatMessage(role: .user, text: "m\($0)") }
    }

    /// The trim is a view of the history for the request, not an edit of it.
    /// It used to assign back to `messages` four lines before `persist()`, so
    /// switching a long conversation to a local model and sending one message
    /// deleted the older ones from disk — with no quarantine copy, and
    /// switching back to a cloud provider did not bring them back.
    func testTrimmingForALocalModelDoesNotMutateTheInput() {
        let history = longHistory()
        let trimmed = ChatSession.historyForLocal(history)
        XCTAssertEqual(history.count, 41, "the source array must be untouched")
        XCTAssertLessThan(trimmed.count, history.count)
    }

    /// What actually reaches disk after a local send.
    func testStoredHistorySurvivesASendOnALocalProvider() {
        let session = ChatSession()
        guard let id = session.newThread() else { return XCTFail("no thread") }
        session.messages = longHistory()
        session.persistPublic()

        var local = ProviderSettings()
        local.presetId = "mlx"
        local.localModelId = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        session.send("noch eine Frage", settings: local)
        session.stop()

        let stored = session.threads.first { $0.id == id }?.messages ?? []
        XCTAssertGreaterThanOrEqual(
            stored.count, 41,
            "the full conversation must still be on disk after a local-model send"
        )
    }

    /// System message and the mini-app source pin are not optional context.
    func testTheWindowKeepsTheSystemMessageAndTheSourcePin() {
        let pin = ChatSession.sourcePinMessage(
            for: ChatSession.EditingContext(id: UUID(), name: "App", html: "<html></html>")
        )
        let history = [ChatMessage(role: .system, text: "system"), pin]
            + (0..<30).map { ChatMessage(role: .user, text: "m\($0)") }
        let trimmed = ChatSession.historyForLocal(history)
        XCTAssertEqual(trimmed.first?.role, .system)
        XCTAssertTrue(trimmed.contains { ChatSession.isSourcePinMessage($0) })
    }
}

/// A group discussion must keep asking the roster it began with.
@MainActor
final class GroupRoundScopingTests: XCTestCase {

    /// Rounds 2+ re-derived the thread from `activeThreadId`. Leaving a running
    /// group for a solo chat therefore ran the next round against the solo
    /// chat, which has no participants — so the user got "Keine aktiven Agenten
    /// in dieser Gruppe" in a conversation that never was one.
    func testParticipantsResolveAgainstANamedThreadNotWhateverIsOpen() {
        let session = ChatSession()
        let members = [UUID(), UUID()]
        guard let group = session.newThread(participantAgentIds: members) else {
            return XCTFail("no group thread")
        }
        session.messages = [ChatMessage(role: .user, text: "gruppe")]
        session.persistPublic()
        guard let solo = session.newThread() else { return XCTFail("no solo thread") }
        session.messages = [ChatMessage(role: .user, text: "solo")]
        session.persistPublic()
        session.switchTo(threadId: solo)

        XCTAssertTrue(session.activeParticipants.isEmpty, "the open thread is solo")
        // The group's own roster is still reachable by id while another
        // conversation is on screen — which is what a later round needs.
        XCTAssertEqual(
            session.threads.first { $0.id == group }?.participantAgentIds, members
        )
        XCTAssertTrue(session.participants(inThread: solo).isEmpty)
    }
}

/// The mini-app sandbox.
final class SandboxHardeningTests: XCTestCase {

    /// The CSP used to be spliced in after the first literal "<head>" found
    /// anywhere — including inside a leading comment, which mini-apps routinely
    /// have. A document whose comment merely contained that text swallowed the
    /// whole injection and ran with NO policy and no bridge. With
    /// NSAllowsArbitraryLoads on app-wide, that is unrestricted network access
    /// from generated code.
    func testAHeadInsideALeadingCommentCannotSwallowThePolicy() {
        let hostile = """
        <!doctype html>
        <!-- emoji: 🧪  template note: <head> -->
        <html><head><title>x</title></head><body>hi</body></html>
        """
        let hardened = Sandbox.harden(hostile, capability: .offline)

        let cspIndex = hardened.range(of: "Content-Security-Policy")
        XCTAssertNotNil(cspIndex, "every document must carry a policy")
        let commentEnd = hardened.range(of: "-->")
        if let cspIndex, let commentEnd {
            XCTAssertLessThan(
                hardened.distance(from: hardened.startIndex, to: cspIndex.lowerBound),
                hardened.distance(from: hardened.startIndex, to: commentEnd.lowerBound),
                "the policy must precede model-authored markup, not land inside it"
            )
        }
        XCTAssertTrue(hardened.contains("window.miniapp"), "the bridge must survive too")
    }

    func testEveryCapabilityTierStillGetsAPolicyAndTheBridge() {
        for capability in MiniAppCapability.allCases {
            let hardened = Sandbox.harden("<p>plain</p>", capability: capability)
            XCTAssertTrue(hardened.contains("Content-Security-Policy"), capability.rawValue)
            XCTAssertTrue(hardened.contains(capability.rawValue), capability.rawValue)
            XCTAssertTrue(hardened.contains("<!doctype html>"), capability.rawValue)
        }
    }

    func testTheOriginalMarkupIsPreserved() {
        let hardened = Sandbox.harden("<html><head></head><body><h1>Titel</h1></body></html>")
        XCTAssertTrue(hardened.contains("<h1>Titel</h1>"))
    }
}

/// MLX keeps its model in a different field than every other provider.
final class LocalModelFieldTests: XCTestCase {

    /// `makeProvider` builds `MLXProvider(modelId: localModelId)` and never
    /// reads `model`. A gate written against `effectiveModel` therefore
    /// rejected every on-device agent even with a model downloaded and
    /// selected — and the first version of that gate shipped, silencing every
    /// local agent in a group. The earlier unit test missed it by populating
    /// `model`, which the app itself never does for MLX.
    func testMLXReadsLocalModelIdAndNotModel() {
        var settings = ProviderSettings()
        settings.presetId = "mlx"
        settings.model = ""                                     // as the app leaves it
        settings.localModelId = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

        XCTAssertTrue(
            settings.effectiveModel.trimmingCharacters(in: .whitespaces).isEmpty,
            "this is the field a naive gate checks — and it is empty by design"
        )
        guard let provider = settings.makeProvider(apiKey: "") as? MLXProvider else {
            return XCTFail("mlx must build an MLXProvider")
        }
        XCTAssertEqual(provider.modelId, settings.localModelId,
                       "the provider uses localModelId, so the gate must too")
    }

    /// The preset has no default, which is why the empty case must be caught.
    func testTheMLXPresetHasNoDefaultModelToFallBackOn() {
        XCTAssertTrue(ProviderPreset.preset(for: "mlx").defaultModel.isEmpty)
    }
}

/// The German source text is the lookup key in `Localizable.xcstrings`, so
/// editing a literal in Swift silently renames its catalog entry and orphans
/// all sixteen translations — the string then falls back to German everywhere.
/// These read the catalog out of the source tree (it is compiled into `.strings`
/// by the time it reaches the bundle, so there is nothing to read at runtime).
final class StringCatalogTests: XCTestCase {

    /// ar, bn, en, es, fr, hi, id, it, ja, ko, pt, ru, tr, ur, vi, zh-Hans.
    /// `de` is the source language and has no entry of its own.
    static let shippedLanguages: Set<String> = [
        "ar", "bn", "en", "es", "fr", "hi", "id", "it",
        "ja", "ko", "pt", "ru", "tr", "ur", "vi", "zh-Hans",
    ]

    private func catalog() throws -> [String: [String: Any]] {
        let url = URL(fileURLWithPath: #filePath)      // AIAppTests/ShipReadinessTests.swift
            .deletingLastPathComponent()               // AIAppTests/
            .deletingLastPathComponent()               // repo root
            .appendingPathComponent("AIApp/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = json as? [String: Any],
              let strings = root["strings"] as? [String: [String: Any]] else {
            throw XCTSkip("catalog not readable from \(url.path)")
        }
        return strings
    }

    private func languages(of entry: [String: Any]) -> Set<String> {
        let locs = (entry["localizations"] as? [String: Any]) ?? [:]
        return Set(locs.keys)
    }

    /// The renamed key must exist and must have brought every translation with
    /// it. A rename that drops a language is exactly the failure this guards.
    func testTheWebAppAddressPlaceholderKeptAllSixteenTranslations() throws {
        let strings = try catalog()
        let key = "Adresse (z. B. youtube.com)"
        guard let entry = strings[key] else {
            return XCTFail("the address placeholder key is missing — a rename orphaned it")
        }
        XCTAssertEqual(languages(of: entry), Self.shippedLanguages,
                       "\(key) lost or gained a language")
        for (lang, loc) in (entry["localizations"] as? [String: [String: Any]]) ?? [:] {
            let value = ((loc["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
            XCTAssertTrue(value.contains("youtube.com"),
                          "\(lang) still shows a stale example domain: \(value)")
        }
    }

    /// The old example was a private domain that meant nothing to users; it must
    /// not survive anywhere in the catalog, in any language.
    func testNoLocalizationStillAdvertisesThePrivateExampleDomain() throws {
        for (key, entry) in try catalog() {
            XCTAssertFalse(key.contains("allo.restaurant"), "stale key: \(key)")
            for (lang, loc) in (entry["localizations"] as? [String: [String: Any]]) ?? [:] {
                let value = ((loc["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
                XCTAssertFalse(value.contains("allo.restaurant"),
                               "stale value in \(lang) for \(key)")
            }
        }
    }

    /// A typo in a locale code (`zh-hans`, `pt-BR`) produces an entry Xcode
    /// happily stores and the app never reads. No key may introduce one, and no
    /// key may be left with no translations at all.
    func testEveryKeyUsesOnlyTheShippedLocaleCodes() throws {
        for (key, entry) in try catalog() {
            let langs = languages(of: entry)
            XCTAssertFalse(langs.isEmpty, "\(key) has no localizations at all")
            XCTAssertTrue(langs.isSubset(of: Self.shippedLanguages),
                          "\(key) has unknown locale codes: \(langs.subtracting(Self.shippedLanguages))")
        }
    }

    /// Every format specifier in a key, keyed by the argument it consumes.
    ///
    /// Plain `%@` consume arguments in order; `%2$@` names one explicitly. A
    /// translation may reorder freely with the positional form, so comparing
    /// index → type (rather than the raw sequence) is the only check that both
    /// permits a legitimate reorder and catches a real mismatch. `%%` is an
    /// escaped percent sign and consumes nothing.
    private func formatSpecifiers(of text: String) -> [Int: String] {
        let pattern = "%(?:([0-9]+)\\$)?[-+ #0]*[0-9]*(?:\\.[0-9]+)?(hh|h|ll|l|q|z|t|j|L)?([@dioruxXeEfgGcsSpaA%])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ns = text as NSString
        var found: [Int: String] = [:]
        var auto = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func group(_ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            guard let conversion = group(3), conversion != "%" else { continue }
            let index: Int
            if let explicit = group(1), let parsed = Int(explicit) {
                index = parsed
            } else {
                auto += 1
                index = auto
            }
            found[index] = (group(2) ?? "") + conversion
        }
        return found
    }

    /// A dropped or reordered specifier is not a cosmetic bug: `String(format:)`
    /// fills the slots positionally, so a `%@` that went missing in Japanese
    /// reads the next argument off the stack and can crash. Every language of
    /// every key must consume exactly the arguments the German source key does.
    func testEveryTranslationConsumesTheSameFormatArgumentsAsItsKey() throws {
        for (key, entry) in try catalog() {
            let source = formatSpecifiers(of: key)
            for (lang, loc) in (entry["localizations"] as? [String: [String: Any]]) ?? [:] {
                let value = ((loc["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
                XCTAssertEqual(formatSpecifiers(of: value), source,
                               "\(lang) changes the format arguments of \(key): \(value)")
            }
        }
    }

    /// The on-device memory gate is the one place where a German fallback hurts
    /// most: the crash it explains was reported from a zh-Hans device, so the
    /// user who needs the sentence is the one who would not have understood it.
    /// These are the keys Swift actually extracts — the source literals contain
    /// interpolations and are *not* the keys.
    func testTheLocalModelMemoryGateIsTranslatedEverywhere() throws {
        let strings = try catalog()
        let keys = [
            "Braucht ~%@ — dieses iPhone (%@) gibt einer App ~%@": 3,
            "Dieses iPhone hat %@ und gibt einer App davon ~%@. Modelle, die mehr brauchen, lassen sich nicht laden.": 2,
        ]
        for (key, slots) in keys {
            // Spelling the count out keeps the parser honest: one that found
            // nothing would make every equality check below pass vacuously.
            XCTAssertEqual(formatSpecifiers(of: key), Dictionary(
                uniqueKeysWithValues: (1...slots).map { ($0, "@") }
            ), "the source key no longer takes \(slots) arguments")
            guard let entry = strings[key] else {
                XCTFail("memory-gate key missing, so it falls back to German everywhere: \(key)")
                continue
            }
            XCTAssertEqual(languages(of: entry), Self.shippedLanguages,
                           "\(key) is not translated into every shipped language")
            for (lang, loc) in (entry["localizations"] as? [String: [String: Any]]) ?? [:] {
                let value = ((loc["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(lang) has an empty translation for \(key)")
                XCTAssertEqual(formatSpecifiers(of: value), formatSpecifiers(of: key),
                               "\(lang) does not fill the same slots as \(key)")
            }
        }
    }
}
