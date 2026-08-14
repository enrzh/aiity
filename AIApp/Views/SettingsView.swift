import SwiftUI
import SwiftData

/// Compact settings hub — short rows, no essay footers.
struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject private var prefs = AppPreferences.shared
    @ObservedObject private var sync = SyncStatus.shared
    @EnvironmentObject private var session: ChatSession
    @Query private var savedApps: [MiniApp]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var backupURL: URL?
    /// Visible (and announced) failure of the last backup attempt — a nil from
    /// writeBackup must not end in silence.
    @State private var backupError: String?
    @State private var backupSummary = "…"
    @State private var showImporter = false
    /// Outcome of the last import attempt — success summary or error. nil
    /// until one ran; shown in the backup section footer.
    @State private var importStatus: String?
    @State private var needsRestartNotice = false
    @State private var diagnosticsSummary = String(localized: "Letzter Lauf prüfen")

    var body: some View {
        NavigationStack {
            Form {
                Section("KI") {
                    NavigationLink {
                        ConnectionsView()
                    } label: {
                        AppSettingsRow(
                            title: String(localized: "Anbieter"),
                            subtitle: activeLine,
                            systemImage: "cpu"
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                    .accessibilityIdentifier("open-connections")

                    NavigationLink {
                        SkillsView()
                    } label: {
                        AppSettingsRow(title: String(localized: "Skills"), systemImage: "puzzlepiece.extension")
                    }
                    .accessibilityIdentifier("open-skills")

                    NavigationLink {
                        MCPServersView()
                    } label: {
                        AppSettingsRow(
                            title: "MCP Server",
                            subtitle: "Externe Werkzeuge verbinden",
                            systemImage: "shippingbox"
                        )
                    }
                    .accessibilityIdentifier("open-mcp-servers")

                    NavigationLink {
                        AgentToolsSettingsView()
                    } label: {
                        AppSettingsRow(
                            title: String(localized: "Agent-Werkzeuge"),
                            subtitle: agentToolsLine,
                            systemImage: "calendar.badge.clock"
                        )
                    }
                    .accessibilityIdentifier("open-agent-tools")

                    NavigationLink {
                        SearchSettingsView()
                    } label: {
                        AppSettingsRow(
                            title: String(localized: "Web-Suche"),
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
                        withAnimation(Theme.Motion.preferSpring(Theme.Motion.soft, reduceMotion: reduceMotion)) {
                            needsRestartNotice = true
                        }
                        // Same text as the footer that just appeared below the fold.
                        AccessibilityNotification.Announcement(String(localized: "Wird nach dem nächsten Start der App wirksam. Es geht nichts verloren — beide Modi öffnen denselben lokalen Speicher.")).post()
                    }

                    AppSettingsRow(
                        title: sync.title,
                        // `subtitle` swaps in the last CloudKit failure (quota,
                        // auth, network) when there is one — "iCloud aktiv" must
                        // not stand unqualified while every export quietly fails.
                        subtitle: sync.subtitle,
                        systemImage: sync.systemImage
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sync-status")
                } header: {
                    Text("Daten")
                } footer: {
                    if needsRestartNotice {
                        // Honest rather than convenient: the store is opened once
                        // at launch and cannot switch modes while running.
                        Label {
                            Text("Wird nach dem nächsten Start der App wirksam. Es geht nichts verloren — beide Modi öffnen denselben lokalen Speicher.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("Aus heißt: alles bleibt nur auf diesem Gerät. Es wird nichts gelöscht.")
                    }
                }

                // Kept alongside iCloud, not replaced by it: sync mirrors a
                // deletion to every device, so an exportable copy is still the
                // only thing that survives "I deleted it everywhere".
                Section {
                    Button {
                        let url = BackupService.writeBackup(apps: savedApps, createdAt: .now)
                        withAnimation(Theme.Motion.preferSpring(Theme.Motion.soft, reduceMotion: reduceMotion)) {
                            backupURL = url
                            backupError = url == nil
                                ? String(localized: "Backup-Datei konnte nicht erstellt werden.")
                                : nil
                        }
                        AccessibilityNotification.Announcement(
                            url != nil
                                ? String(localized: "Backup erstellt — Teilen verfügbar")
                                : String(localized: "Backup-Datei konnte nicht erstellt werden.")
                        ).post()
                    } label: {
                        Label("Backup-Datei erstellen", systemImage: "arrow.down.doc")
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
                        Label("Backup einspielen", systemImage: "arrow.up.doc")
                    }
                    .accessibilityIdentifier("import-backup")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let backupError {
                            Text(backupError).foregroundStyle(.red)
                        }
                        if let importStatus {
                            Text(importStatus)
                        }
                        Text(backupSummary)
                        // Honest about the two restore semantics: apps merge per
                        // item, but chats/skills/agents are whole-file and only
                        // land on a device that has none of its own yet.
                        Text("Einmalige Kopie zum Weggeben oder Archivieren. iCloud spiegelt auch Löschungen — eine Datei nicht. Beim Einspielen werden Mini-Apps nur ergänzt, nie überschrieben oder gelöscht; Chats, Skills und Agenten werden nur übernommen, wenn dieses Gerät noch keine eigenen hat.")
                    }
                }

                Section("Anzeige") {
                    Picker(selection: $prefs.appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    } label: {
                        Label("Erscheinungsbild", systemImage: prefs.appearance.systemImage)
                    }
                    .accessibilityIdentifier("appearance-picker")

                    Toggle(isOn: $prefs.keepScreenAwakeWhileBuilding) {
                        Label("Bildschirm an beim Build", systemImage: "sun.max")
                    }
                    .accessibilityIdentifier("keep-screen-awake")
                }

                Section {
                    Toggle(isOn: $prefs.allowLocalTools) {
                        Label("Web-Tools für lokale Modelle", systemImage: "globe")
                    }
                    .accessibilityIdentifier("allow-local-tools")
                } header: {
                    Text("Datenschutz")
                } footer: {
                    Text("Standard für Ollama, LM Studio, LocalAI und On-Device. Jeder Anbieter kann das unter Mehr → KI-Anbieter → Werkzeuge überschreiben — an wie aus.")
                }

                Section {
                    Toggle(isOn: $prefs.smartSuggestions) {
                        Label("Ideen vom Modell", systemImage: "lightbulb")
                    }
                    .accessibilityIdentifier("smart-suggestions")

                    NavigationLink {
                        PrivacyDetailView()
                    } label: {
                        Label("Datenschutz", systemImage: "hand.raised")
                    }
                } footer: {
                    Text("Ideen vom Modell holt im leeren Chat höchstens einmal am Tag ein paar Vorschläge bei deinem eigenen KI-Anbieter — ohne Chat-Inhalte, ohne Titel, ohne App-Namen. Nur mit API-Key und selbst gewähltem Modell, nie mit Abo-Login oder lokalem Modell.")
                }

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        AppSettingsRow(
                            title: String(localized: "Diagnose"),
                            subtitle: diagnosticsSummary,
                            systemImage: "stethoscope"
                        )
                    }
                    .accessibilityIdentifier("open-diagnostics")
                } footer: {
                    Text("Zeigt, wie der letzte Lauf geendet ist, und lässt den Bericht direkt teilen — ohne Umweg über die iOS-Einstellungen.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
            }
            .navigationTitle("Mehr")
            .task {
                backupSummary = BackupService.summary(apps: savedApps)
                let snapshot = DiagnosticsRecorder.shared.lastRunSnapshot()
                diagnosticsSummary = String(localized: "Letzter Lauf: \(DiagnosticsReport.headline(snapshot.verdict, run: snapshot.run))")
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { outcome in
                importBackup(outcome)
            }
            // One announcement path for the whole import flow: wait notice,
            // success summary, and every error land here.
            .onChange(of: importStatus) { _, status in
                if let status {
                    AccessibilityNotification.Announcement(status).post()
                }
            }
        }
    }

    /// Read the picked file and merge it. Files from the document picker are
    /// security-scoped — without the access pair the read fails with a
    /// permission error that looks like a corrupt backup.
    private func importBackup(_ outcome: Result<[URL], Error>) {
        guard case .success(let urls) = outcome, let url = urls.first else {
            if case .failure(let error) = outcome {
                importStatus = error.localizedDescription
            }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            importStatus = error.localizedDescription
            return
        }

        // Restoring while the FIRST CloudKit import is still in flight would
        // insert records whose UUIDs may be seconds away from arriving via
        // iCloud too — duplicates CloudKit can never dedup. Wait it out (the
        // 20 s timeout in SyncStatus bounds this); usually it settled long
        // before the user reached this screen and the wait is zero.
        if !sync.initialImportComplete {
            importStatus = String(localized: "Warte auf iCloud-Abgleich …")
        }
        Task {
            await sync.waitUntilInitialImportSettled()
            // Drain chat writes before BackupService decides whether the on-disk
            // archive is empty. Otherwise an older debounced snapshot can land
            // after the import and overwrite the restored conversation.
            guard await session.flushPersistence() else {
                importStatus = String(localized: "Chat-Verlauf konnte vor dem Import nicht gesichert werden.")
                return
            }
            await applyBackup(data)
        }
    }

    private func applyBackup(_ data: Data) async {
        do {
            let existing = Set(savedApps.map(\.id))
            let (result, apps) = try BackupService.restore(from: data, existingIds: existing)
            for app in apps { modelContext.insert(app) }
            // Reporting success after swallowing the save error tells the user
            // their apps were restored when they were not.
            try modelContext.save()
            // Defense in depth behind the wait above: if duplicates DID get in
            // (older builds, an import racing a later sync), fold them —
            // conservatively, see MiniAppDedup.
            MiniAppDedup.removeDuplicates(in: modelContext)
            // The import wrote chat/skill/agent files under live stores that
            // still hold their own state — without a reload the next save
            // overwrites everything just restored. This was done for chats
            // only; AgentStore.reload() existed and was called from nowhere, so
            // an imported roster stayed invisible, the user concluded the
            // import had failed, and creating one agent wrote that single agent
            // over the restored file.
            try await session.reloadFromDisk()
            AgentStore.shared.reload()
            // SkillStore has no shared instance — each view constructs its own
            // and therefore reads the restored file on next appearance, so it
            // needs no reload here.
            importStatus = result.summary
            backupSummary = BackupService.summary(apps: savedApps)
        } catch {
            importStatus = error.localizedDescription
        }
    }

    /// Names what the agent may currently touch — nothing at all is the
    /// default, and the row says so rather than looking configured.
    private var agentToolsLine: String {
        guard prefs.deviceToolsEnabled else { return String(localized: "Aus") }
        var parts: [String] = []
        if PersonalData.store.access(.reminders).canWrite { parts.append(String(localized: "Erinnerungen")) }
        if PersonalData.store.access(.calendar).canWrite { parts.append(String(localized: "Kalender")) }
        if !UserFileAccess.shared.entries.isEmpty {
            parts.append(String(localized: "\(UserFileAccess.shared.entries.count) Datei(en)"))
        }
        return parts.isEmpty ? String(localized: "Nichts freigegeben") : parts.joined(separator: " · ")
    }

    private var activeLine: String {
        let s = settingsStore.settings
        let model = s.effectiveModel
        if model.isEmpty { return s.preset.label }
        return "\(s.preset.label) · \(model)"
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
                     ? String(localized: "DuckDuckGo braucht keinen Key und ist die Standardquelle.")
                     : String(localized: "Braucht einen eigenen Key bzw. Server. Ohne gültige Angaben fällt die Suche auf DuckDuckGo zurück."))
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
