import Foundation

/// One conversation. The session keeps the active thread's messages live in
/// `messages` and mirrors them back into `threads` on every persist.
struct ChatThread: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var messages: [ChatMessage] = []
    var editingContext: ChatSession.EditingContext?
    var updatedAt = Date()
}

/// Drives one user turn: stream the model's answer, execute requested tools,
/// feed results back, repeat (bounded), and extract a generated mini-app from
/// the final answer if one is present. App-wide object (EnvironmentObject);
/// all threads persist across app restarts.
@MainActor
final class ChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var busy = false
    @Published var statusLine: String?
    @Published var errorMessage: String?
    @Published var draftMiniApp: MiniAppDraft?
    /// Tab selection lives here so the library can hand a mini-app to the chat.
    @Published var activeTab = 0
    @Published private(set) var threads: [ChatThread] = []
    private var activeThreadId = UUID()

    /// Set when the chat continues work on a saved mini-app.
    var editingContext: EditingContext?

    struct EditingContext: Codable, Equatable {
        var id: UUID
        var name: String
        var html: String
    }

    private static let maxToolRounds = 6

    init() {
        restore()
    }

    static let systemPrompt = """
    You are AI App, an assistant that chats normally AND can build small apps ("mini-apps") on request.

    When the user asks you to create or change an app, answer with a short explanation plus ONE complete, self-contained HTML document in a ```html code fence. Rules for mini-apps:
    - Single file: all CSS and JS inline. No external resources (no CDNs, fonts, images from the network) — the runtime blocks them.
    - Set a short app name in <title> and start the document with <!-- emoji: X --> where X is one fitting emoji.
    - Bridge APIs available inside mini-apps:
      * `await miniapp.storage.get(key)` / `await miniapp.storage.set(key, value)` — persistent JSON storage, namespaced per app.
      * `miniapp.haptic()` — light haptic tap.
      * `await miniapp.notify(title, body, inSeconds)` — schedules a local notification (asks permission on first use; returns {ok, id?, error?}). Great for timers and reminders.
      * `await miniapp.health.query(type, days)` — reads Apple Health; type is "steps", "activeEnergy" or "heartRate"; returns {ok, data: [{date: "YYYY-MM-DD", value}]}. Asks permission on first use; data may be empty if denied — always handle that gracefully.

    # Quality bar — every mini-app must feel like a real iOS app
    - COMPLETE functionality: no TODOs, no placeholders, no dead buttons. Every visible control works.
    - Load persisted state on start, save on every change (miniapp.storage). The app must survive being closed and reopened with all user data intact.
    - Mobile-first for an iPhone viewport: meta viewport, safe areas via env(safe-area-inset-*), no horizontal scrolling, touch targets of at least 44px.
    - Full dark mode: CSS custom properties for every color, switched via @media (prefers-color-scheme: dark).
    - Polished visuals: -apple-system font stack, consistent spacing scale, rounded cards, subtle transitions (150-250ms), pressed states on buttons.
    - Handle edge cases: empty states with a friendly hint, input validation with inline feedback, division-by-zero etc.
    - Use miniapp.haptic() on meaningful actions (add, complete, error).
    - Prefer more thorough, feature-complete apps over minimal sketches — include the 2-3 features a user would obviously expect next (edit, delete, undo, totals …).

    You have web tools (web_search, fetch_url) — use them to research facts, APIs, formulas or current information before answering or building. If the app depends on real-world data (prices, formulas, rules), research first and bake verified values in.
    Answer in the language the user writes in.
    """

    func send(_ input: String, settings: ProviderSettings) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        errorMessage = nil
        if messages.isEmpty {
            var system = Self.systemPrompt
            let skillInstructions = SkillStore.enabledInstructions()
            if !skillInstructions.isEmpty {
                system += "\n\n# Installed skills — follow them when relevant\n\(skillInstructions)"
            }
            if let context = editingContext {
                system += "\n\nThe user is editing the existing mini-app \"\(context.name)\". Its current source:\n```html\n\(context.html)\n```\nWhen asked for changes, output the FULL updated document."
            }
            messages.append(ChatMessage(role: .system, text: system))
        }
        messages.append(ChatMessage(role: .user, text: text))
        persist()
        busy = true

        let provider = settings.makeProvider(apiKey: Keychain.get(settings.keychainAccount))
        let tools = ToolRegistry.makeTools(settings: settings)

        Task {
            await runTurn(provider: provider, tools: tools)
            busy = false
            statusLine = nil
            persist()
        }
    }

    private func runTurn(provider: LLMProvider, tools: [AgentTool]) async {
        let specs = tools.map(\.spec)
        let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.spec.name, $0) })

        for _ in 0..<Self.maxToolRounds {
            messages.append(ChatMessage(role: .assistant, text: ""))
            let assistantIndex = messages.count - 1
            var requestedCalls: [ToolCallData] = []

            do {
                for try await event in provider.streamChat(messages: Array(messages[..<assistantIndex]), tools: specs) {
                    switch event {
                    case .textDelta(let delta):
                        messages[assistantIndex].text += delta
                    case .toolCall(let call):
                        requestedCalls.append(call)
                    case .done:
                        break
                    }
                }
            } catch {
                messages.remove(at: assistantIndex)
                errorMessage = error.localizedDescription
                return
            }

            messages[assistantIndex].toolCalls = requestedCalls
            if requestedCalls.isEmpty {
                draftMiniApp = MiniAppDraft.extract(from: messages[assistantIndex].text)
                return
            }

            for call in requestedCalls {
                statusLine = Self.statusText(for: call)
                let result = await toolsByName[call.name]?.run(argumentsJSON: call.argumentsJSON)
                    ?? "Error: unknown tool \(call.name)"
                messages.append(ChatMessage(role: .tool, text: result, toolCallId: call.id, toolName: call.name))
            }
            statusLine = nil
        }
        errorMessage = "Zu viele Tool-Runden — abgebrochen."
    }

    private static func statusText(for call: ToolCallData) -> String {
        let arguments = toolArguments(call.argumentsJSON)
        switch call.name {
        case "web_search": return "Sucht im Web: \(arguments["query"] as? String ?? "…")"
        case "fetch_url": return "Liest \(arguments["url"] as? String ?? "Seite")…"
        default: return "Führt \(call.name) aus…"
        }
    }

    // MARK: - Threads

    func newThread() {
        guard !busy else { return }
        syncActiveIntoThreads()
        let thread = ChatThread()
        threads.insert(thread, at: 0)
        activeThreadId = thread.id
        loadActiveThread()
        persist()
    }

    func switchTo(threadId: UUID) {
        guard !busy, threadId != activeThreadId,
              threads.contains(where: { $0.id == threadId }) else { return }
        syncActiveIntoThreads()
        activeThreadId = threadId
        loadActiveThread()
        persist()
    }

    func deleteThread(_ threadId: UUID) {
        guard !busy else { return }
        threads.removeAll { $0.id == threadId }
        if threadId == activeThreadId {
            if let next = threads.max(by: { $0.updatedAt < $1.updatedAt }) {
                activeThreadId = next.id
            } else {
                let fresh = ChatThread()
                threads = [fresh]
                activeThreadId = fresh.id
            }
            loadActiveThread()
        }
        persist()
    }

    var activeThreadTitle: String {
        threads.first(where: { $0.id == activeThreadId })?.title ?? ""
    }

    /// Entry point from the library: continue a saved mini-app in a new thread.
    func startEditing(id: UUID, name: String, html: String) {
        newThread()
        editingContext = EditingContext(id: id, name: name, html: html)
        activeTab = 0
        persist()
    }

    private func loadActiveThread() {
        let thread = threads.first(where: { $0.id == activeThreadId }) ?? ChatThread()
        messages = thread.messages
        editingContext = thread.editingContext
        errorMessage = nil
        statusLine = nil
        draftMiniApp = messages.last(where: { $0.role == .assistant }).flatMap { MiniAppDraft.extract(from: $0.text) }
    }

    private func syncActiveIntoThreads() {
        guard let index = threads.firstIndex(where: { $0.id == activeThreadId }) else {
            if !messages.isEmpty {
                threads.insert(currentSnapshotThread(), at: 0)
            }
            return
        }
        threads[index] = currentSnapshotThread(existing: threads[index])
    }

    private func currentSnapshotThread(existing: ChatThread? = nil) -> ChatThread {
        var thread = existing ?? ChatThread(id: activeThreadId)
        thread.id = activeThreadId
        thread.messages = messages
        thread.editingContext = editingContext
        if !messages.isEmpty { thread.updatedAt = .now }
        if thread.title.isEmpty {
            if let context = editingContext {
                thread.title = "✏️ \(context.name)"
            } else if let firstUser = messages.first(where: { $0.role == .user }) {
                thread.title = String(firstUser.text.prefix(48))
            }
        }
        return thread
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var threads: [ChatThread]
        var activeThreadId: UUID
    }

    /// v1 single-conversation format, migrated on first launch.
    private struct LegacySnapshot: Codable {
        var messages: [ChatMessage]
        var editingContext: EditingContext?
    }

    private static let storeURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("chat-threads.json")
    }()

    private static let legacyStoreURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chat-session.json")
    }()

    private func persist() {
        syncActiveIntoThreads()
        let snapshot = Snapshot(threads: threads, activeThreadId: activeThreadId)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }

    private func restore() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           !snapshot.threads.isEmpty {
            threads = snapshot.threads
            activeThreadId = snapshot.threads.contains(where: { $0.id == snapshot.activeThreadId })
                ? snapshot.activeThreadId
                : snapshot.threads[0].id
        } else if let data = try? Data(contentsOf: Self.legacyStoreURL),
                  let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data),
                  !legacy.messages.isEmpty {
            var thread = ChatThread(messages: legacy.messages, editingContext: legacy.editingContext)
            if let firstUser = legacy.messages.first(where: { $0.role == .user }) {
                thread.title = String(firstUser.text.prefix(48))
            }
            threads = [thread]
            activeThreadId = thread.id
            try? FileManager.default.removeItem(at: Self.legacyStoreURL)
        } else {
            let fresh = ChatThread()
            threads = [fresh]
            activeThreadId = fresh.id
        }
        loadActiveThread()
    }
}

/// A mini-app the model just produced, before the user decides to keep it.
struct MiniAppDraft: Equatable {
    var name: String
    var emoji: String
    var html: String

    static func extract(from text: String) -> MiniAppDraft? {
        guard let fenceStart = text.range(of: "```html"),
              let fenceEnd = text.range(of: "```", range: fenceStart.upperBound..<text.endIndex) else {
            return nil
        }
        let html = String(text[fenceStart.upperBound..<fenceEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard html.lowercased().contains("<html") || html.lowercased().contains("<!doctype") else { return nil }

        var name = "Mini-App"
        if let titleStart = html.range(of: "<title>", options: .caseInsensitive),
           let titleEnd = html.range(of: "</title>", options: .caseInsensitive, range: titleStart.upperBound..<html.endIndex) {
            let title = String(html[titleStart.upperBound..<titleEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { name = title }
        }
        var emoji = "✨"
        if let match = html.range(of: #"<!--\s*emoji:\s*(\S+)\s*-->"#, options: .regularExpression) {
            let comment = String(html[match])
            if let value = comment.components(separatedBy: "emoji:").last?
                .replacingOccurrences(of: "-->", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                emoji = String(value.prefix(2))
            }
        }
        return MiniAppDraft(name: name, emoji: emoji, html: html)
    }
}
