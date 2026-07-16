import SwiftUI

struct SettingsView: View {
    @State private var settings = ProviderSettings.load()
    @State private var newKey = ""
    @State private var newLabel = ""
    @State private var availableModels: [String] = []
    @State private var modelsError: String?
    @State private var fetchingModels = false
    @State private var authError: String?
    @State private var pendingPaste: OAuthService.PendingPaste?
    @StateObject private var accountStore = AccountStore()
    @StateObject private var modelStore = LocalModelStore()
    @StateObject private var oauth = OAuthService()

    private var providerAccounts: [Account] { accountStore.accounts(for: settings.presetId) }
    private var activeAccount: Account? { accountStore.activeAccount(for: settings.presetId) }

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                if settings.preset.dialect != .mlx {
                    accountsSection
                }
                if settings.preset.dialect == .mlx {
                    Section("Lokale Modelle") { localModelRows }
                } else {
                    modelSection
                }
                searchSection
            }
            .navigationTitle("Einstellungen")
            .onChange(of: settings.presetId) {
                settings.baseURL = ""
                settings.model = ""
                availableModels = []
                modelsError = nil
                authError = nil
            }
            .onChange(of: settings) { settings.save() }
            .sheet(item: $pendingPaste) { pending in
                PasteCodeSheet(
                    providerLabel: settings.preset.label,
                    busy: oauth.busy,
                    onCancel: { pendingPaste = nil },
                    onSubmit: { completePasteFlow(pending, code: $0) }
                )
            }
        }
    }

    // MARK: Provider

    private var providerSection: some View {
        Section {
            Picker("Anbieter", selection: $settings.presetId) {
                ForEach(ProviderPreset.catalog) { preset in
                    Text(preset.label).tag(preset.id)
                }
            }
            if settings.preset.editableBaseURL {
                TextField(
                    settings.preset.defaultBaseURL.isEmpty
                        ? "Server-Adresse (z. B. ki.meine-domain.de)"
                        : "Base-URL (Standard: \(settings.preset.defaultBaseURL))",
                    text: $settings.baseURL
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                if !settings.baseURL.isEmpty, settings.effectiveBaseURL != settings.baseURL {
                    Text("→ \(settings.effectiveBaseURL)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("KI-Anbieter")
        } footer: {
            Text(providerFooter)
        }
    }

    // MARK: Accounts (multi)

    private var accountsSection: some View {
        Section {
            ForEach(providerAccounts) { account in
                Button {
                    accountStore.setActive(account)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: account.id == activeAccount?.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(account.id == activeAccount?.id ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.label)
                            Text(account.isOAuth ? "Abo-Login (OAuth)" : "API-Key")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) { accountStore.delete(account) } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                }
            }

            // Add an account.
            if settings.preset.needsKey || settings.preset.editableBaseURL {
                SecureField("Neuer API-Key", text: $newKey)
                if !newKey.isEmpty {
                    TextField("Bezeichnung (optional, z. B. „Privat“)", text: $newLabel)
                        .autocorrectionDisabled()
                    Button {
                        accountStore.addKeyAccount(presetId: settings.presetId, label: newLabel, key: newKey)
                        newKey = ""; newLabel = ""
                    } label: {
                        Label("Key als Konto hinzufügen", systemImage: "plus.circle")
                    }
                }
            }
            if settings.preset.oauth != nil {
                Button {
                    signInWithOAuth()
                } label: {
                    if oauth.busy {
                        ProgressView()
                    } else {
                        Label("Konto per \(settings.preset.label.components(separatedBy: " ")[0]) hinzufügen", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                .disabled(oauth.busy)
            }
            if let authError {
                Text(authError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Konten")
        } footer: {
            Text(providerAccounts.isEmpty
                 ? "Noch kein Konto — Key eintragen oder per Abo-Login anmelden."
                 : "Mehrere Konten möglich; das angehakte wird verwendet.")
        }
    }

    private var providerFooter: String {
        switch settings.presetId {
        case "mlx":
            return "Modelle laufen komplett auf dem Gerät (Apple MLX) — offline, privat, kostenlos. Download einmalig über WLAN empfohlen. Im Simulator nicht verfügbar."
        case "anthropic":
            return "Abo-Login nutzt dein Claude-Abo per CLI-OAuth (Claude-Code-Flow): Browser öffnet sich, du autorisierst, kopierst den angezeigten Code zurück. Alternativ API-Key."
        case "openrouter":
            return "Abo-Login per OAuth holt automatisch einen API-Key — oder eigenen Key einfügen."
        case "openai":
            return "Abo-Login nutzt dein ChatGPT-Abo per Codex-CLI-OAuth (Code kopieren). Läuft über OpenAIs Codex-Backend — die App verhält sich dabei wie die Codex-CLI. Alternativ API-Key oder GPT per OpenRouter."
        case "xai":
            return "Abo-Login nutzt dein SuperGrok / X-Premium+-Abo per grok-cli-OAuth (Code kopieren) — läuft über den Grok-CLI-Proxy. Alternativ API-Key oder Grok per OpenRouter."
        case "sub2api":
            return "Server-Adresse deiner sub2api-Instanz eintragen (nur der Host reicht, „/v1“ wird ergänzt) und den sub2api-Key als API-Key. Danach „Modelle laden“ tippen."
        default:
            if settings.preset.editableBaseURL {
                return "Für eigene Server: Base-URL des kompatiblen Endpoints eintragen (Ollama, LM Studio, LocalAI, vLLM, LiteLLM …)."
            }
            return "Der API-Key wird nur im Geräte-Keychain gespeichert."
        }
    }

    private func signInWithOAuth() {
        authError = nil
        guard let config = settings.preset.oauth else { return }
        if config.flow == .openRouterKeyExchange {
            let preset = settings.preset
            Task {
                do {
                    if case .apiKey(let key) = try await oauth.signInOpenRouter(preset: preset) {
                        accountStore.addKeyAccount(presetId: preset.id, label: "OpenRouter", key: key)
                    }
                } catch {
                    authError = error.localizedDescription
                }
            }
            return
        }
        guard let pending = oauth.startPasteFlow(preset: settings.preset) else { return }
        UIApplication.shared.open(pending.authorizeURL)
        pendingPaste = pending
    }

    private func completePasteFlow(_ pending: OAuthService.PendingPaste, code: String) {
        authError = nil
        let presetId = settings.presetId
        let label = settings.preset.label.components(separatedBy: " ")[0]
        Task {
            do {
                if case .credential(let credential) = try await oauth.completePasteFlow(pending, pasted: code) {
                    accountStore.addOAuthAccount(presetId: presetId, label: label, credential: credential)
                    pendingPaste = nil
                }
            } catch {
                authError = error.localizedDescription
            }
        }
    }

    // MARK: Model selection

    private var modelSection: some View {
        Section {
            if availableModels.isEmpty {
                TextField(
                    settings.preset.defaultModel.isEmpty ? "Modell-ID" : "Modell (Standard: \(settings.preset.defaultModel))",
                    text: $settings.model
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            } else {
                Picker("Modell", selection: $settings.model) {
                    if !settings.model.isEmpty && !availableModels.contains(settings.model) {
                        Text(settings.model).tag(settings.model)
                    }
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.navigationLink)
            }
            Button {
                fetchModels()
            } label: {
                if fetchingModels {
                    ProgressView()
                } else {
                    Label(availableModels.isEmpty ? "Modelle laden" : "Modelle aktualisieren (\(availableModels.count))", systemImage: "arrow.clockwise")
                }
            }
            .disabled(fetchingModels)
            if let modelsError {
                Text(modelsError).font(.caption).foregroundStyle(.red)
            }
            TextField("Bild-Modell (generate_image)", text: $settings.imageModel)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Video-Modell (generate_video)", text: $settings.videoModel)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("Modell")
        } footer: {
            Text("Chat-Modell oben. Bild/Video nutzen die OpenAI-kompatiblen Endpoints /images/generations bzw. /videos des Anbieters.")
        }
    }

    private func fetchModels() {
        fetchingModels = true
        modelsError = nil
        let snapshot = settings
        Task {
            do {
                let key = await AuthStore.effectiveKey(for: snapshot)
                let models = try await ModelCatalogService.fetchModels(settings: snapshot, apiKey: key)
                availableModels = models
                if models.isEmpty { modelsError = "Keine Modelle gemeldet." }
                if settings.model.isEmpty, let first = models.first {
                    settings.model = snapshot.preset.defaultModel.isEmpty ? first : snapshot.preset.defaultModel
                }
            } catch {
                modelsError = error.localizedDescription
            }
            fetchingModels = false
        }
    }

    private var searchSection: some View {
        Section {
            TextField("SearXNG-Endpoint (optional)", text: $settings.searchEndpoint)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
        } header: {
            Text("Web-Suche")
        } footer: {
            Text("Leer = eingebaute DuckDuckGo-Suche. Eigene SearXNG-Instanz liefert stabilere Ergebnisse.")
        }
    }

    // MARK: Local (MLX) models

    @ViewBuilder
    private var localModelRows: some View {
        ForEach(LocalModel.catalog) { model in
            HStack(spacing: 12) {
                Button {
                    settings.localModelId = model.id
                } label: {
                    HStack {
                        Image(systemName: settings.localModelId == model.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(settings.localModelId == model.id ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                            Text(model.details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if let fraction = modelStore.progress[model.id] {
                    ProgressView(value: fraction)
                        .frame(width: 60)
                } else if modelStore.downloadedIds.contains(model.id) {
                    Button(role: .destructive) {
                        modelStore.delete(model.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button {
                        modelStore.download(model.id)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        if let error = modelStore.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

/// Collects the authorization code after the provider's browser flow. The
/// user copies the code (Claude) or the whole localhost redirect URL
/// (OpenAI/Grok) shown after approving, and pastes it here.
private struct PasteCodeSheet: View {
    let providerLabel: String
    let busy: Bool
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Im Browser hast du \(providerLabel) autorisiert. Kopiere den angezeigten Code — oder die ganze Weiterleitungs-URL (localhost) aus der Adresszeile — und füge ihn hier ein.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Code oder Weiterleitungs-URL") {
                    TextField("Code einfügen", text: $code, axis: .vertical)
                        .lineLimit(1...4)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        if let clip = UIPasteboard.general.string { code = clip }
                    } label: {
                        Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .navigationTitle("Anmeldung abschließen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Verbinden") { onSubmit(code) }
                            .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
