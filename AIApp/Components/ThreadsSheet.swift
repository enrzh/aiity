import SwiftUI

/// Conversation list modal — tap to switch, swipe to delete.
struct ThreadsSheet: View {
    @EnvironmentObject private var session: ChatSession
    @Environment(\.dismiss) private var dismiss

    private var sortedThreads: [ChatThread] {
        session.threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        AppSheet {
            NavigationStack {
                List {
                    ForEach(sortedThreads) { thread in
                        Button {
                            session.switchTo(threadId: thread.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.title.isEmpty ? "Neuer Chat" : thread.title)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(thread.updatedAt.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("thread-row")
                        .swipeActions {
                            Button(role: .destructive) {
                                session.deleteThread(thread.id)
                            } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                        }
                    }
                }
                .navigationTitle("Chats")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            session.newThread()
                            dismiss()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
            }
        }
    }
}
