import SwiftUI
import SwiftData

/// Saved mini-apps grid. Chat lives on its own tab — this is the home for kept apps.
struct LibraryView: View {
    @Query(sort: \MiniApp.updatedAt, order: .reverse) private var apps: [MiniApp]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var session: ChatSession
    @Environment(\.openChatTab) private var openChatTab
    @ObservedObject private var sync = SyncStatus.shared
    @State private var openApp: MiniApp?
    @State private var iconEditApp: MiniApp?
    @State private var showAddWebApp = false
    @State private var deleteCandidate: MiniApp?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 16)]

    var body: some View {
        NavigationStack {
            Group {
                if apps.isEmpty && !sync.initialImportComplete {
                    // An empty query and a store still waiting on its FIRST
                    // CloudKit import look identical — without this, someone
                    // reopening the app on a new device sees "no apps yet"
                    // seconds before their apps actually arrive, and reasonably
                    // reads that as sync being broken rather than just slow.
                    syncingState
                } else if apps.isEmpty {
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
            // No title: the tab bar already says "Apps" right below this screen,
            // so a large "Meine Apps" header just repeated it and ate a row of
            // grid space.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddWebApp = true
                    } label: {
                        Image(systemName: "globe.badge.chevron.backward")
                    }
                    .accessibilityIdentifier("add-webapp")
                    .accessibilityLabel("Website als App hinzufügen")
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
            // Deleting a mini-app is irreversible and propagates to every
            // device over iCloud, so it keeps one confirmation step.
            // Centered alert, deliberately NOT a confirmationDialog: the
            // bottom sheet reads as a menu continuation of the long-press that
            // opened it, and the destructive step deserves to interrupt in the
            // middle of the screen rather than slide up under the thumb.
            .alert(
                String(localized: "Mini-App löschen?"),
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                ),
                presenting: deleteCandidate
            ) { app in
                Button("Löschen", role: .destructive) {
                    // A browser app keeps a persistent WKWebsiteDataStore with
                    // its cookies and logins. Deleting only the record leaves
                    // that session on disk forever, tied to nothing. This
                    // returns immediately and WebKit usually REFUSES the
                    // deletion in this process (it opened the store when the
                    // app was last run); the identifier is queued durably and
                    // the next launch's MiniAppSessionStoreSweep finishes it.
                    MiniAppRunnerView.removeSessionStore(for: app.id.uuidString)
                    MiniAppConsent.revoke(appId: app.id.uuidString)
                    modelContext.delete(app)
                    deleteCandidate = nil
                }
                .accessibilityIdentifier("library-app-delete-confirm")
                Button("Abbrechen", role: .cancel) { deleteCandidate = nil }
            } message: { app in
                Text(String(localized: "„\(app.name)“ wird dauerhaft entfernt."))
            }
        }
    }

    private var emptyState: some View {
        AppEmptyState(
            title: String(localized: "Noch keine Apps"),
            systemImage: "square.grid.2x2",
            message: String(localized: "Im Chat bauen und behalten."),
            actionTitle: String(localized: "Zum Chat"),
            action: openChatTab,
            showsTileMotif: true
        )
    }

    private var syncingState: some View {
        AppEmptyState(
            title: String(localized: "Suche nach deinen Apps"),
            systemImage: "icloud.and.arrow.down",
            message: String(localized: "iCloud gleicht gerade ab — deine Apps von anderen Geräten sollten gleich erscheinen.")
        )
    }

    private func appCard(_ app: MiniApp) -> some View {
        Button {
            Theme.Haptics.tap()
            openApp = app
        } label: {
            MiniAppTile(
                name: app.name,
                emoji: app.emoji,
                iconSymbol: app.iconSymbol,
                capabilityLabel: app.capability == .offline ? nil : app.capability.label
            )
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("library-app")
        // The library is a grid, and `.swipeActions` only exists on List rows —
        // so the delete affordance is the long-press menu, which is what a grid
        // of app tiles uses everywhere else on iOS.
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
                deleteCandidate = app
            } label: {
                Label("Löschen", systemImage: "trash")
            }
            .accessibilityIdentifier("library-app-delete")
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
        AppSheet(detents: [.medium]) {
            addWebAppContent
        }
    }

    private var addWebAppContent: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Adresse (z. B. youtube.com)", text: $url)
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
        AppSheet {
            iconPickerContent
        }
    }

    private var iconPickerContent: some View {
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
                                    .background(emojiDraft == e ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
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
                                    .background(symbolDraft == s ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
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
    }
}
