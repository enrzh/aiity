import Foundation
import Combine

/// The one channel from an App Intent into the running UI.
///
/// Every user-facing aiity intent is `openAppWhenRun` — it needs the chat
/// surface, the mini-app sandbox or the composer, none of which exist headless.
/// `perform()` therefore does not *do* the thing; it writes down what the user
/// asked for and lets `RootView` carry it out once a scene exists.
///
/// Why the indirection rather than calling `ChatSession` from `perform()`:
///  * On a **cold launch** the intent can run before `RootView` (and therefore
///    before `ChatSession`) exists at all. A direct call would have nothing to
///    call. The pending request survives that gap and is consumed on appear.
///  * On a **warm launch** the intent runs in the same process as the live
///    session, and the `@Published` change drives the route immediately.
///
/// The counter matters: asking twice for the same thing ("neuer Chat", then
/// "neuer Chat" again) must route twice, and `Route` alone would compare equal
/// and drop the second one.
@MainActor
final class IntentRouter: ObservableObject {
    static let shared = IntentRouter()

    enum Route: Equatable {
        /// Fresh solo conversation. `prompt` may be empty.
        case newChat(prompt: String)
        /// Open a saved mini-app in the sandboxed runner.
        case openMiniApp(id: UUID)
        /// Fresh conversation with exactly one agent as participant.
        case askAgent(id: UUID, question: String)
    }

    struct Request: Equatable {
        let sequence: Int
        let route: Route
    }

    @Published private(set) var pending: Request?

    /// Text an intent wants in the composer. **Never sent automatically** —
    /// `ChatView` fills the field and raises the keyboard, the user presses
    /// send. Same decision as dictation: a Shortcut must not be able to spend
    /// tokens (or trigger a local model load) without the user seeing the text
    /// first and agreeing to it.
    @Published var stagedComposerText: String?

    private var sequence = 0

    private init() {}

    func request(_ route: Route) {
        sequence += 1
        pending = Request(sequence: sequence, route: route)
    }

    /// Take the pending route. Consuming clears it so a later unrelated
    /// re-render cannot replay the same navigation.
    func consumeRoute() -> Route? {
        defer { pending = nil }
        return pending?.route
    }

    func takeStagedText() -> String? {
        defer { stagedComposerText = nil }
        let text = stagedComposerText
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    /// Test seam: drop everything queued.
    func resetForTesting() {
        pending = nil
        stagedComposerText = nil
        sequence = 0
    }
}

/// Name matching shared by every entity query.
///
/// Siri hands `entities(matching:)` whatever it heard, which is rarely an exact
/// title: wrong case, a missing umlaut, or only part of the name. Pure and
/// synchronous on purpose — it is the part worth unit-testing, and keeping it
/// out of the query keeps the query down to a file read plus this call.
enum IntentNameMatch {
    /// Fold case, diacritics and surrounding whitespace so "Ubersetzer",
    /// "übersetzer" and " Übersetzer " all reach the same key.
    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
    }

    /// Entries whose name matches `query`, prefix hits first.
    ///
    /// An empty query returns everything unchanged — Shortcuts uses that to
    /// populate the parameter picker, and returning nothing there is exactly
    /// the "my apps never show up" failure this is meant to avoid.
    static func filter<T>(_ items: [T], query: String, name: (T) -> String) -> [T] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return items }
        var prefixHits: [T] = []
        var containsHits: [T] = []
        for item in items {
            let candidate = normalize(name(item))
            if candidate.hasPrefix(needle) {
                prefixHits.append(item)
            } else if candidate.contains(needle) {
                containsHits.append(item)
            }
        }
        return prefixHits + containsHits
    }
}
