import SwiftUI
import SwiftData

struct ChatView: View {
    @EnvironmentObject private var session: ChatSession
    @State private var input = ""
    @State private var previewDraft: MiniAppDraft?
    @Environment(\.modelContext) private var modelContext

    private var visibleMessages: [ChatMessage] {
        session.messages.filter {
            $0.role == .user || ($0.role == .assistant && !ChatView.strippingHTMLFence(from: $0.text).isEmpty)
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
            .navigationTitle("AI App")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.reset()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(session.busy)
                }
            }
            .sheet(item: $previewDraft) { draft in
                MiniAppSheet(appId: "preview", name: draft.name, html: draft.html)
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

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.role == .assistant ? ChatView.strippingHTMLFence(from: message.text) : message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    message.role == .user ? Color.accentColor.opacity(0.9) : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
            if message.role == .assistant { Spacer(minLength: 40) }
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
