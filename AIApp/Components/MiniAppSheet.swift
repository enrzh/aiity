import SwiftUI

/// Sheet hosting a sandboxed mini-app. Chrome: **AI · Title · Done**.
/// Tapping AI dismisses and opens Chat linked to this app for further edits.
struct MiniAppSheet: View {
    let appId: String
    let name: String
    let html: String
    /// Saved library id when known — AI button wires chat to this app.
    var libraryId: UUID? = nil
    var emoji: String = "✨"
    var iconSymbol: String? = nil
    var allowsNetwork: Bool = false
    /// Called after dismiss when user wants AI edits (host switches to Chat tab).
    var onEditWithAI: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: ChatSession
    @Environment(\.openChatTab) private var openChatTab

    var body: some View {
        NavigationStack {
            MiniAppRunnerView(
                appId: appId,
                html: html,
                capability: MiniAppCapability.from(html: html)
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        openAIEdit()
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityLabel("Mit KI bearbeiten")
                    .accessibilityIdentifier("miniapp-ai-edit")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        MiniAppIconView(emoji: emoji, iconSymbol: iconSymbol, size: 22)
                        Text(name)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("miniapp-done")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func openAIEdit() {
        if let libraryId {
            session.startEditing(id: libraryId, name: name, html: html)
        } else {
            session.startEditingDraft(name: name, html: html, emoji: emoji)
        }
        dismiss()
        // Defer so sheet dismissal doesn't fight tab switch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            openChatTab()
            onEditWithAI?()
        }
    }
}

/// Renders mini-app icon: SF Symbol if set, else emoji.
struct MiniAppIconView: View {
    var emoji: String
    var iconSymbol: String?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let symbol = iconSymbol, !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: size, height: size)
            } else {
                Text(emoji.isEmpty ? "✨" : emoji)
                    .font(.system(size: size * 0.72))
                    .frame(width: size, height: size)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}
