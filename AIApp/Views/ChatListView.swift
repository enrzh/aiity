import SwiftUI

/// The Chat tab's root: every conversation as a row, newest first. Opening a
/// chat pushes it — so going back to the list is the system back gesture rather
/// than a modal sheet, and the list is what you see when the tab opens.
struct ChatListView: View {
    @EnvironmentObject private var session: ChatSession
    @ObservedObject private var agentStore = AgentStore.shared
    @State private var showNewChat = false
    @State private var deleteCandidate: ChatThread?

    private var threads: [ChatThread] {
        session.threads
            .filter { !$0.messages.isEmpty || $0.id == session.openThreadId }
            .sorted { $0.updatedAt > $1.updatedAt }
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
                    AppEmptyState(
                        title: String(localized: "Noch keine Chats"),
                        systemImage: "bubble.left.and.bubble.right",
                        message: String(localized: "Starte eine Unterhaltung — allein mit der KI oder als Gruppe mit mehreren Agenten."),
                        actionTitle: String(localized: "Neuer Chat"),
                        action: { startSolo() }
                    )
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
            .confirmationDialog(
                String(localized: "Chat löschen?"),
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                ),
                presenting: deleteCandidate
            ) { thread in
                Button("Löschen", role: .destructive) {
                    session.deleteThread(thread.id)
                    deleteCandidate = nil
                }
                Button("Abbrechen", role: .cancel) { deleteCandidate = nil }
            } message: { thread in
                Text("„\(thread.title.isEmpty ? "Neuer Chat" : thread.title)“ wird entfernt.")
            }
        }
    }

    private func row(_ thread: ChatThread) -> some View {
        Button {
            session.open(threadId: thread.id)
        } label: {
            HStack(spacing: 12) {
                avatar(for: thread)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(thread.title.isEmpty ? "Neuer Chat" : thread.title)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.caption2)
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
                    } else if thread.isGroup {
                        Text(participantNames(thread))
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("thread-row")
        .swipeActions {
            Button(role: .destructive) {
                deleteCandidate = thread
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    /// Group chats show their members' emoji; a solo chat shows the app mark.
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
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            } else {
                Text(emojis.joined())
                    .font(emojis.count > 1 ? .caption : .title3)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: 44, height: 44)
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
        NavigationStack {
            List {
                Section {
                    Button {
                        onCreate([])
                        dismiss()
                    } label: {
                        Label("Nur mit der KI", systemImage: "sparkles")
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
                                    Text(agent.emoji)
                                    Text(agent.name)
                                        .foregroundStyle(.primary)
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
        .presentationDetents([.medium, .large])
    }
}
