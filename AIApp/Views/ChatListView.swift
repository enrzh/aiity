import SwiftUI

/// The Chat tab's root: every conversation as a row, newest first. Opening a
/// chat pushes it — so going back to the list is the system back gesture rather
/// than a modal sheet, and the list is what you see when the tab opens.
struct ChatListView: View {
    @EnvironmentObject private var session: ChatSession
    @ObservedObject private var agentStore = AgentStore.shared
    @State private var showNewChat = false
    @State private var searchText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var threads: [ChatThread] {
        let visible = session.threads
            .filter { !$0.messages.isEmpty || $0.id == session.openThreadId }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard !searchText.isEmpty else { return visible }
        return visible.filter { thread in
            if thread.title.localizedStandardContains(searchText) { return true }
            return agentStore.agents.contains {
                thread.participantAgentIds.contains($0.id)
                    && $0.name.localizedStandardContains(searchText)
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            // Surfaced here rather than buried in Mehr: after a crash this is
            // the first screen the user lands on.
            CrashNoticeBanner()
                .padding(.top, 4)

            Group {
                if threads.isEmpty {
                    if !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        AppEmptyState(
                            title: String(localized: "Noch keine Chats"),
                            systemImage: "bubble.left.and.bubble.right",
                            message: String(localized: "Starte eine Unterhaltung — allein mit der KI oder als Gruppe mit mehreren Agenten."),
                            actionTitle: String(localized: "Neuer Chat"),
                            action: { startSolo() }
                        )
                    }
                } else {
                    List {
                        ForEach(threads) { thread in
                            row(thread)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            }
            .navigationTitle("Chats")
            // On the stack root, not the List: the field must survive the swap
            // to ContentUnavailableView when a query matches nothing.
            .searchable(text: $searchText)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityIdentifier("new-chat")
                    .accessibilityLabel("Neuer Chat")
                }
            }
            .navigationDestination(item: $session.openThreadId) { _ in
                ChatView()
                    .environmentObject(session)
            }
            .sheet(isPresented: $showNewChat) {
                NewChatSheet(agents: agentStore.agents) { participants in
                    startChat(participants: participants)
                }
            }
            // No confirmation on swipe (user request): the swipe itself is the
            // deliberate gesture, and this is how Mail and Messages behave.
            // Mini-apps and agents still confirm — those are authored work,
            // and a mini-app also owns a persistent cookie jar.
        }
    }

    private func row(_ thread: ChatThread) -> some View {
        Button {
            session.open(threadId: thread.id)
        } label: {
            HStack(spacing: Theme.space2) {
                avatar(for: thread)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(thread.title.isEmpty ? "Neuer Chat" : thread.title)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Text(thread.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if session.runningThreadId == thread.id {
                        // A round keeps running when you leave the chat, so the
                        // list has to say so — otherwise it looks stalled.
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("läuft…")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                        .transition(.opacity)
                    } else if thread.isGroup {
                        Text(participantNames(thread))
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .animation(
                Theme.Motion.preferSpring(Theme.Motion.snappy, reduceMotion: reduceMotion),
                value: session.runningThreadId
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("thread-row")
        .swipeActions {
            Button(role: .destructive) {
                session.deleteThread(thread.id)
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    /// Group chats show their members' emoji, a solo chat the brand mark at
    /// monogram scale — both on the same neutral circle, so rows don't compete
    /// with each other on hue.
    @ViewBuilder
    private func avatar(for thread: ChatThread) -> some View {
        let emojis = agentStore.agents
            .filter { thread.participantAgentIds.contains($0.id) }
            .prefix(2)
            .map(\.emoji)

        ZStack {
            Circle()
                .fill(Color(.secondarySystemBackground))
            if emojis.isEmpty {
                // tileSize 13 → mark ≈28pt, the monogram ratio for a 44pt circle.
                AiityTileMark(tileSize: 13)
            } else {
                Circle()
                    .strokeBorder(.quaternary, lineWidth: 0.5)
                Text(emojis.joined())
                    .font(emojis.count > 1 ? .caption : .title3)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }

    private func participantNames(_ thread: ChatThread) -> String {
        let names = agentStore.agents
            .filter { thread.participantAgentIds.contains($0.id) }
            .map(\.name)
        return names.isEmpty ? String(localized: "Gruppe") : names.joined(separator: ", ")
    }

    private func startSolo() {
        startChat(participants: [])
    }

    private func startChat(participants: [UUID]) {
        guard let id = session.newThread(participantAgentIds: participants) else { return }
        session.open(threadId: id)
    }
}

/// Choose who is in the new conversation: nobody (just the assistant) or any
/// number of the user's agents.
struct NewChatSheet: View {
    var agents: [AgentDefinition]
    var onCreate: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    var body: some View {
        AppSheet {
            newChatContent
        }
    }

    private var newChatContent: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onCreate([])
                        dismiss()
                    } label: {
                        Label("Nur mit der KI", systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier("new-solo-chat")
                } footer: {
                    Text("Der normale Chat, der auch Mini-Apps baut.")
                }

                if agents.isEmpty {
                    Section {
                        Text("Noch keine Agenten angelegt — im Tab „Agenten“ erstellen, dann kannst du sie hier in eine Gruppe holen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(agents) { agent in
                            Button {
                                if selected.contains(agent.id) {
                                    selected.remove(agent.id)
                                } else {
                                    selected.insert(agent.id)
                                }
                            } label: {
                                HStack {
                                    // Label, not a bare HStack: keeps the emoji
                                    // in the same icon column as the row above.
                                    Label {
                                        Text(agent.name)
                                            .foregroundStyle(.primary)
                                    } icon: {
                                        Text(agent.emoji)
                                    }
                                    Spacer()
                                    if selected.contains(agent.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .accessibilityIdentifier("group-agent-option")
                        }
                    } header: {
                        Text("Gruppe")
                    } footer: {
                        Text("Ausgewählte Agenten antworten in dieser Unterhaltung mit — jeder mit seinem eigenen Modell.")
                    }
                }
            }
            .navigationTitle("Neuer Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gruppe starten") {
                        onCreate(Array(selected))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("start-group-chat")
                }
            }
        }
    }
}
