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
    @State private var showAddWebApp = false

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddWebApp = true
                    } label: {
                        Image(systemName: "globe.badge.chevron.backward")
                    }
                    .accessibilityIdentifier("add-webapp")
                }
            }
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
            .sheet(isPresented: $showAddWebApp) {
                AddWebAppSheet { url, name in
                    let host = WebAppBuilder.host(of: url)
                    modelContext.insert(MiniApp(
                        name: name.isEmpty ? host : name,
                        emoji: "🌐",
                        html: WebAppBuilder.html(urlString: url, name: name),
                        filesJSON: "{}",
                        iconSymbol: "globe"
                    ))
                }
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

/// Create a browser mini-app that opens a website (login persists per app).
struct AddWebAppSheet: View {
    var onCreate: (_ url: String, _ name: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""

    private var isValid: Bool {
        let t = url.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.contains(".")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Adresse (z. B. app.allo.restaurant)", text: $url)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("webapp-url")
                    TextField("Name (optional)", text: $name)
                        .accessibilityIdentifier("webapp-name")
                } header: {
                    Text("Website als App öffnen")
                } footer: {
                    Text("Öffnet die Seite in einem eingebauten Browser. Du siehst die Seite, kannst dich einloggen und sie normal nutzen — der Login bleibt pro App gespeichert.")
                }
            }
            .navigationTitle("Web-App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen") {
                        onCreate(url.trimmingCharacters(in: .whitespaces), name.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                    .accessibilityIdentifier("webapp-create")
                }
            }
        }
        .presentationDetents([.medium])
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
