import XCTest
@testable import AIApp

/// Regression guard for a bug that reached a running build: adding
/// `participantAgentIds` to `ChatThread` made every stored thread fail to
/// decode, because Swift's synthesized decoder does NOT fall back to a
/// property's default value for a missing key. One throw failed the whole
/// array and the app opened with an empty chat list on top of a 440 KB file of
/// real conversations — which the next save would have overwritten.
final class ThreadDecodingTests: XCTestCase {

    /// A thread as written by a build that predates group chats.
    private let legacyJSON = """
    {
      "id": "6C7A5C03-496D-4DFA-A509-29E08C8173A2",
      "title": "Öffne example.com",
      "updatedAt": 770000000,
      "messages": [
        {"id":"8B3EC27E-D74F-4FEE-A34D-AFC99BBCBA6A","role":"user","text":"Hallo"}
      ]
    }
    """

    func testThreadWithoutParticipantsStillDecodes() throws {
        let thread = try JSONDecoder().decode(ChatThread.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(thread.title, "Öffne example.com")
        XCTAssertEqual(thread.messages.count, 1)
        XCTAssertTrue(thread.participantAgentIds.isEmpty)
        XCTAssertFalse(thread.isGroup)
    }

    /// The failure mode was array-wide: one undecodable element took the rest
    /// of the history with it.
    func testAnArrayOfLegacyThreadsDecodesWhole() throws {
        let array = "[\(legacyJSON),\(legacyJSON),\(legacyJSON)]"
        let threads = try JSONDecoder().decode([ChatThread].self, from: Data(array.utf8))
        XCTAssertEqual(threads.count, 3)
    }

    func testGroupParticipantsSurviveARoundTrip() throws {
        let members = [UUID(), UUID()]
        let original = ChatThread(title: "Planung", participantAgentIds: members)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatThread.self, from: data)
        XCTAssertEqual(decoded.participantAgentIds, members)
        XCTAssertTrue(decoded.isGroup)
    }

    // MARK: - List preview

    func testPreviewUsesTheLastRealMessage() {
        let thread = ChatThread(messages: [
            ChatMessage(role: .user, text: "Erste Frage"),
            ChatMessage(role: .assistant, text: "Eine Antwort\nmit Umbruch"),
        ])
        XCTAssertEqual(thread.preview, "Eine Antwort mit Umbruch")
    }

    /// Tool traffic and the hidden mini-app source pin are not conversation.
    func testPreviewSkipsToolAndPinnedSourceMessages() {
        let pin = ChatSession.sourcePinMessage(
            for: ChatSession.EditingContext(id: UUID(), name: "App", html: "<html></html>")
        )
        let thread = ChatThread(messages: [
            ChatMessage(role: .assistant, text: "Sichtbare Antwort"),
            ChatMessage(role: .tool, text: "{\"results\": []}", toolName: "web_search"),
            pin,
        ])
        XCTAssertEqual(thread.preview, "Sichtbare Antwort")
    }

    func testEmptyThreadHasAPlaceholderPreview() {
        XCTAssertEqual(ChatThread().preview, "Noch keine Nachrichten")
    }
}

/// The conversation list orders by real activity, not by what you looked at.
final class ThreadOrderingTests: XCTestCase {
    @MainActor
    func testOpeningAConversationDoesNotReorderTheList() {
        let session = ChatSession()
        let older = Date(timeIntervalSince1970: 1_000_000)

        // A thread whose last activity was long ago.
        guard let id = session.newThread() else { return XCTFail("could not create a thread") }
        session.messages = [ChatMessage(role: .user, text: "alt")]
        session.persistPublic()

        // Backdate it, then merely open it again.
        let before = session.threads.first { $0.id == id }?.updatedAt ?? older
        session.open(threadId: id)
        session.persistPublic()
        let after = session.threads.first { $0.id == id }?.updatedAt ?? Date()

        XCTAssertEqual(
            before.timeIntervalSince1970, after.timeIntervalSince1970, accuracy: 0.001,
            "opening a conversation must not count as activity"
        )
    }
}

/// The appearance override is a user choice that must survive a relaunch.
final class AppAppearanceTests: XCTestCase {
    func testSystemFollowsTheDevice() {
        // nil is how SwiftUI expresses "don't override".
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)
    }

    func testEveryOptionIsLabelledAndPersistable() {
        XCTAssertEqual(AppAppearance.allCases.count, 3)
        for option in AppAppearance.allCases {
            XCTAssertFalse(option.title.isEmpty, option.rawValue)
            XCTAssertFalse(option.systemImage.isEmpty, option.rawValue)
            XCTAssertEqual(AppAppearance(rawValue: option.rawValue), option)
        }
    }
}
