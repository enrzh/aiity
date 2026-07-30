import SwiftUI
import SwiftData

/// Compact settings hub — short rows, no essay footers.
struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject private var prefs = AppPreferences.shared
    @ObservedObject private var sync = SyncStatus.shared
    @Query private var savedApps: [MiniApp]
    @Environment(\.modelContext) private var modelContext
    @State private var backupURL: URL?
    @State private var backupSummary = "…"
    @State private var showImporter = false
    @State private var importSummary = "Aus einer Backup-Datei ergänzen"
    @State private var needsRestartNotice = false

    var body: some View {
        NavigationStack {
            Form {
                Section("KI") {
                    NavigationLink {
                        ConnectionsView()
                    } label: {
                        AppSettingsRow(
                            title: "Anbieter",
                            subtitle: activeLine,
                            systemImage: "cpu"
                        )
                    }
                    .accessibilityIdentifier("open-connections")

                    NavigationLink {
                        SkillsView()
                    } label: {
                        AppSettingsRow(title: "Skills", systemImage: "puzzlepiece.extension")
                    }
                    .accessibilityIdentifier("open-skills")

                    NavigationLink {
                        SearchSettingsView()
                    } label: {
                        AppSettingsRow(
                            title: "Web-Suche",
                            subtitle: SearchBackend(rawValue: settingsStore.settings.searchBackend)?.title,
                            systemImage: "magnifyingglass"
                        )
                    }
                }

                Section {
                    Toggle(isOn: $prefs.iCloudSyncEnabled) {
                        Label("iCloud-Sync", systemImage: "icloud")
                    }
                    .accessibilityIdentifier("icloud-toggle")
                    .onChange(of: prefs.iCloudSyncEnabled) { _, _ in
                        needsRestartNotice = true
                    }

                    AppSettingsRow(
                        title: sync.title,
                        subtitle: sync.detail,
                        systemImage: sync.systemImage
                    )
                    .accessibilityIdentifier("sync-status")
                } header: {
                    Text("Daten")
                } footer: {
                    if needsRestartNotice {
                        // Honest rather than convenient: the store is opened once
                        // at launch and cannot switch modes while running.
                        Text("Wird nach dem nächsten Start der App wirksam. Es geht nichts verloren — beide Modi öffnen denselben lokalen Speicher.")
                            .foregroundStyle(Color.orange)
                    } else {
                        Text("Aus heißt: alles bleibt nur auf diesem Gerät. Es wird nichts gelöscht.")
                    }
                }

                // Kept alongside iCloud, not replaced by it: sync mirrors a
                // deletion to every device, so an exportable copy is still the
                // only thing that survives "I deleted it everywhere".
                Section {
                    Button {
                        backupURL = BackupService.writeBackup(apps: savedApps, createdAt: .now)
                    } label: {
                        AppSettingsRow(
                            title: "Backup-Datei erstellen",
                            subtitle: backupSummary,
                            systemImage: "arrow.down.doc"
                        )
                    }
                    .accessibilityIdentifier("create-backup")
                    if let backupURL {
                        ShareLink(item: backupURL) {
                            Label("Teilen", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("share-backup")
                    }

                    Button {
                        showImporter = true
                    } label: {
                        AppSettingsRow(
                            title: "Backup einspielen",
                            subtitle: importSummary,
                            systemImage: "arrow.up.doc"
                        )
                    }
                    .accessibilityIdentifier("import-backup")
                } footer: {
                    Text("Einmalige Kopie zum Weggeben oder Archivieren. iCloud spiegelt auch Löschungen — eine Datei nicht. Beim Einspielen wird nur ergänzt, nie überschrieben oder gelöscht.")
                }

                Section("Anzeige") {
                    Toggle(isOn: $prefs.keepScreenAwakeWhileBuilding) {
                        Label("Bildschirm an beim Build", systemImage: "sun.max")
                    }
                    .accessibilityIdentifier("keep-screen-awake")
                }

                Section("Datenschutz") {
                    Toggle(isOn: $prefs.allowLocalTools) {
                        Label("Web-Tools für lokale Modelle", systemImage: "globe")
                    }
                    .accessibilityIdentifier("allow-local-tools")

                    NavigationLink {
                        PrivacyDetailView()
                    } label: {
                        Label("Datenschutz", systemImage: "hand.raised")
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .navigationTitle("Mehr")
            .task { backupSummary = BackupService.summary(apps: savedApps) }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { outcome in
                importBackup(outcome)
            }
        }
    }

    /// Read the picked file and merge it. Files from the document picker are
    /// security-scoped — without the access pair the read fails with a
    /// permission error that looks like a corrupt backup.
    private func importBackup(_ outcome: Result<[URL], Error>) {
        guard case .success(let urls) = outcome, let url = urls.first else {
            if case .failure(let error) = outcome {
                importSummary = error.localizedDescription
            }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let existing = Set(savedApps.map(\.id))
            let (result, apps) = try BackupService.restore(from: data, existingIds: existing)
            for app in apps { modelContext.insert(app) }
            try? modelContext.save()
            importSummary = result.summary
            backupSummary = BackupService.summary(apps: savedApps)
        } catch {
            importSummary = error.localizedDescription
        }
    }

    private var activeLine: String {
        let s = settingsStore.settings
        let model = s.effectiveModel
        if model.isEmpty { return s.preset.label }
        let short = model.count > 28 ? String(model.prefix(26)) + "…" : model
        return "\(s.preset.label) · \(short)"
    }
}

private struct SearchSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    private var settings: Binding<ProviderSettings> { $settingsStore.settings }

    private var selected: SearchBackend {
        SearchBackend(rawValue: settingsStore.settings.searchBackend) ?? .auto
    }

    var body: some View {
        Form {
            Section {
                Picker("Backend", selection: settings.searchBackend) {
                    ForEach(SearchBackend.allCases) { backend in
                        Text(backend.title).tag(backend.rawValue)
                    }
                }
            } footer: {
                Text(selected == .auto || selected == .duckduckgo
                     ? "DuckDuckGo braucht keinen Key und ist die Standardquelle."
                     : "Braucht einen eigenen Key bzw. Server. Ohne gültige Angaben fällt die Suche auf DuckDuckGo zurück.")
            }

            // Only the fields the selected backend actually uses — the others
            // were just three always-visible inputs for services most people
            // never configure.
            if selected == .searxng {
                Section("SearXNG") {
                    TextField("SearXNG-URL", text: settings.searchEndpoint)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
            }
            if selected == .brave {
                Section("Brave") {
                    SecureField("Brave Key", text: settings.searchBraveKey)
                        .textContentType(.password)
                        .onChange(of: settingsStore.settings.searchBraveKey) { _, value in
                            Keychain.set(value, for: "search-brave-key")
                        }
                }
            }
            if selected == .tavily {
                Section("Tavily") {
                    SecureField("Tavily Key", text: settings.searchTavilyKey)
                        .textContentType(.password)
                        .onChange(of: settingsStore.settings.searchTavilyKey) { _, value in
                            Keychain.set(value, for: "search-tavily-key")
                        }
                }
            }
        }
        .navigationTitle("Web-Suche")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyDetailView: View {
    var body: some View {
        List {
            Text("Chats, Mini-Apps und Skills bleiben auf dem Gerät. API-Keys und Logins liegen im Schlüsselbund. aiity betreibt keinen eigenen Server — Anfragen gehen an den Anbieter, den du einrichtest (oder dein Gateway). Web-Suche und fetch_url kontaktieren die gewählte Suchmaschine bzw. die Seite.")
                .font(.body)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
        .navigationTitle("Datenschutz")
        .navigationBarTitleDisplayMode(.inline)
    }
}
