import SwiftUI
import SwiftData
import UIKit

struct ChatView: View {
    @EnvironmentObject private var session: ChatSession
    @State private var input = ""
    @State private var previewDraft: MiniAppDraft?
    @State private var showThreads = false
    @Environment(\.modelContext) private var modelContext

    private var visibleMessages: [ChatMessage] {
        session.messages.filter {
            $0.role == .user
                || ($0.role == .assistant
                    && (!ChatView.strippingHTMLFence(from: $0.text).isEmpty || !$0.mediaIds.isEmpty))
        }
    }

    /// Chat bubbles show only the prose — the mini-app source stays hidden
    /// behind the card. Also truncates a fence that is still streaming in.
    static func strippingHTMLFence(from text: String) -> String {
        guard let fenceStart = text.range(of: "```html") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = String(text[..<fenceStart.lowerBound])
        if let fenceEnd = text.range(of: "```", range: fenceStart.upperBound..<text.endIndex) {
            result += text[fenceEnd.upperBound...]
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if visibleMessages.isEmpty {
                                emptyState
                            }
                            ForEach(visibleMessages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            if let status = session.statusLine {
                                Label(status, systemImage: "globe")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if let draft = session.draftMiniApp {
                                MiniAppCard(
                                    draft: draft,
                                    onPreview: { previewDraft = draft },
                                    onKeep: { keep(draft) }
                                )
                                .id("mini-app-card")
                            }
                            if let error = session.errorMessage {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: visibleMessages.last?.text) {
                        if let lastId = visibleMessages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                    .onChange(of: session.draftMiniApp) {
                        if session.draftMiniApp != nil {
                            proxy.scrollTo("mini-app-card", anchor: .bottom)
                        }
                    }
                    .scrollDismissesKeyboard(.immediately)
                }
                inputBar
            }
            .navigationTitle(session.activeThreadTitle.isEmpty ? "aiity" : session.activeThreadTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showThreads = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .disabled(session.busy)
                    .accessibilityIdentifier("chat-threads")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.newThread()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(session.busy)
                    .accessibilityIdentifier("chat-new")
                }
            }
            .sheet(item: $previewDraft) { draft in
                MiniAppSheet(appId: "preview", name: draft.name, html: draft.html)
            }
            .sheet(isPresented: $showThreads) {
                ThreadsSheet()
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Was soll ich bauen?")
                .font(.title2.bold())
            Text("Beschreib eine kleine App — z. B. „Bau mir einen Trinkgeld-Rechner“ — oder stell einfach eine Frage. Für Recherchen nutze ich das Web.")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Nachricht", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .onSubmit(send)
                .accessibilityIdentifier("chat-input")
            Button(action: send) {
                Image(systemName: session.busy ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 28))
            }
            .disabled(session.busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("chat-send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func send() {
        session.send(input, settings: ProviderSettings.load())
        input = ""
    }

    private func keep(_ draft: MiniAppDraft) {
        if let context = session.editingContext {
            let targetId: UUID = context.id
            let descriptor = FetchDescriptor<MiniApp>(predicate: #Predicate { $0.id == targetId })
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.html = draft.html
                existing.name = draft.name
                existing.emoji = draft.emoji
                existing.version += 1
                existing.updatedAt = .now
                session.draftMiniApp = nil
                return
            }
        }
        modelContext.insert(MiniApp(name: draft.name, emoji: draft.emoji, html: draft.html))
        session.draftMiniApp = nil
    }
}

extension MiniAppDraft: Identifiable {
    var id: String { name + String(html.hashValue) }
}

/// All conversations, newest first — tap to switch, swipe to delete.
struct ThreadsSheet: View {
    @EnvironmentObject private var session: ChatSession
    @Environment(\.dismiss) private var dismiss

    private var sortedThreads: [ChatThread] {
        session.threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
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
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    private var bubbleText: String {
        message.role == .assistant ? ChatView.strippingHTMLFence(from: message.text) : message.text
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                if !bubbleText.isEmpty {
                    Text(bubbleText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            message.role == .user ? Color.accentColor.opacity(0.9) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                }
                ForEach(message.mediaIds, id: \.self) { mediaId in
                    GeneratedMediaView(mediaId: mediaId)
                }
            }
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

/// Renders one generated media item: an image inline, a video as a tappable
/// link (videos may be large remote files, so we don't auto-download them).
private struct GeneratedMediaView: View {
    let mediaId: String

    var body: some View {
        switch MediaStore.kind(of: mediaId) {
        case .image:
            if let data = MediaStore.imageData(for: mediaId), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("generated-image")
            }
        case .videoURL:
            if let url = MediaStore.videoURL(for: mediaId) {
                Link(destination: url) {
                    Label("Video ansehen", systemImage: "play.rectangle.fill")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
}

private struct MiniAppCard: View {
    let draft: MiniAppDraft
    let onPreview: () -> Void
    let onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(draft.emoji).font(.largeTitle)
                VStack(alignment: .leading) {
                    Text(draft.name).font(.headline)
                    Text("Generierte Mini-App").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Vorschau", action: onPreview)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("preview-app")
                Button("Behalten", action: onKeep)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("keep-app")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
