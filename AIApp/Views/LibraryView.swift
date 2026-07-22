import SwiftUI
import SwiftData

/// Saved mini-apps grid. Chat lives on its own tab — this is the home for kept apps.
struct LibraryView: View {
    @Query(sort: \MiniApp.updatedAt, order: .reverse) private var apps: [MiniApp]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var session: ChatSession
    @Environment(\.openChatTab) private var openChatTab
    @State private var openApp: MiniApp?
    @State private var iconEditApp: MiniApp?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 16)]

    var body: some View {
        NavigationStack {
            Group {
                if apps.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(apps) { app in
                                appCard(app)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Meine Apps")
            .sheet(item: $openApp) { app in
                MiniAppSheet(
                    appId: app.id.uuidString,
                    name: app.name,
                    html: app.runnableHTML,
                    libraryId: app.id,
                    emoji: app.emoji,
                    iconSymbol: app.iconSymbol
                )
                .environmentObject(session)
            }
            .sheet(item: $iconEditApp) { app in
                IconPickerSheet(app: app)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Noch keine Mini-Apps")
                .font(.headline)
            Text("Im Chat eine App bauen und „Behalten“ tippen — sie erscheint hier.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                openChatTab()
            } label: {
                Label("Zum Chat", systemImage: "bubble.left.and.bubble.right")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appCard(_ app: MiniApp) -> some View {
        Button {
            openApp = app
        } label: {
            VStack(spacing: 8) {
                MiniAppIconView(emoji: app.emoji, iconSymbol: app.iconSymbol, size: 72)
                Text(app.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if app.capability != .offline {
                    Text(app.capability.label)
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library-app")
        .contextMenu {
            Button {
                session.startEditing(id: app.id, name: app.name, html: app.runnableHTML)
                openChatTab()
            } label: {
                Label("Mit KI bearbeiten", systemImage: "sparkles")
            }
            Button {
                iconEditApp = app
            } label: {
                Label("Icon ändern", systemImage: "paintbrush")
            }
            Button(role: .destructive) {
                modelContext.delete(app)
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }
}

/// Simple emoji + SF Symbol picker for library apps.
struct IconPickerSheet: View {
    @Bindable var app: MiniApp
    @Environment(\.dismiss) private var dismiss
    @State private var emojiDraft: String = ""
    @State private var symbolDraft: String = ""

    private let symbols = [
        "checklist", "timer", "cart", "heart", "book", "calendar",
        "dollarsign.circle", "map", "music.note", "camera", "gamecontroller",
        "leaf", "flame", "bolt", "star", "person", "house", "globe",
    ]
    private let emojis = ["✨", "✅", "⏱", "🛒", "❤️", "📚", "💰", "📍", "🎵", "📷", "🎮", "🌱"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Emoji") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 10) {
                        ForEach(emojis, id: \.self) { e in
                            Button {
                                emojiDraft = e
                                symbolDraft = ""
                            } label: {
                                Text(e).font(.title)
                                    .frame(width: 44, height: 44)
                                    .background(emojiDraft == e ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField("Eigenes Emoji", text: $emojiDraft)
                }
                Section("SF Symbol") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 10) {
                        ForEach(symbols, id: \.self) { s in
                            Button {
                                symbolDraft = s
                            } label: {
                                Image(systemName: s)
                                    .frame(width: 44, height: 44)
                                    .background(symbolDraft == s ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField("Symbol-Name", text: $symbolDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    HStack {
                        Spacer()
                        MiniAppIconView(
                            emoji: emojiDraft.isEmpty ? app.emoji : emojiDraft,
                            iconSymbol: symbolDraft.isEmpty ? nil : symbolDraft,
                            size: 72
                        )
                        Spacer()
                    }
                }
            }
            .navigationTitle("Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        if !emojiDraft.isEmpty { app.emoji = String(emojiDraft.prefix(4)) }
                        app.iconSymbol = symbolDraft.isEmpty ? nil : symbolDraft
                        app.updatedAt = .now
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                emojiDraft = app.emoji
                symbolDraft = app.iconSymbol ?? ""
            }
        }
        .presentationDetents([.medium, .large])
    }
}
