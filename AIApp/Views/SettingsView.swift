import SwiftUI

struct SettingsView: View {
    @State private var settings = ProviderSettings.load()
    @State private var apiKey = ""
    @State private var oauthConnected = false
    @State private var availableModels: [String] = []
    @State private var modelsError: String?
    @State private var fetchingModels = false
    @State private var oauthError: String?
    @State private var pendingPaste: OAuthService.PendingPaste?
    @StateObject private var modelStore = LocalModelStore()
    @StateObject private var oauth = OAuthService()

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                if settings.preset.dialect == .mlx {
                    Section("Lokale Modelle") { localModelRows }
                } else {
                    modelSection
                }
                searchSection
            }
            .navigationTitle("Einstellungen")
            .onAppear { reloadKey() }
            .onChange(of: settings.presetId) {
                settings.baseURL = ""
                settings.model = ""
                availableModels = []
                modelsError = nil
                reloadKey()
            }
            .onChange(of: settings) { settings.save() }
            .onChange(of: apiKey) {
                // Never let the (programmatically cleared) key field wipe a
                // stored OAuth credential.
                if !oauthConnected { Keychain.set(apiKey, for: settings.keychainAccount) }
            }
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

    // MARK: Provider + Auth

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
                        ? "Base-URL (z. B. https://ki.meine-domain.de/v1)"
                        : "Base-URL (Standard: \(settings.preset.defaultBaseURL))",
                    text: $settings.baseURL
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            }
            if settings.preset.dialect != .mlx {
                if oauthConnected {
                    HStack {
                        Label("Per OAuth verbunden", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Abmelden", role: .destructive) { disconnectOAuth() }
                    }
                } else {
                    SecureField(settings.preset.needsKey ? "API-Key" : "API-Key (optional)", text: $apiKey)
                    if settings.preset.oauth != nil {
                        Button {
                            signInWithOAuth()
                        } label: {
                            if oauth.busy {
                                ProgressView()
                            } else {
                                Label("Mit \(settings.preset.label.components(separatedBy: " ")[0]) anmelden", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                        .disabled(oauth.busy)
                    }
                }
                if let oauthError {
                    Text(oauthError).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("KI-Anbieter")
        } footer: {
            Text(providerFooter)
        }
    }

    private var providerFooter: String {
        switch settings.presetId {
        case "mlx":
            return "Modelle laufen komplett auf dem Gerät (Apple MLX) — offline, privat, kostenlos. Download einmalig über WLAN empfohlen. Im Simulator nicht verfügbar."
        case "anthropic":
            return "„Mit Anthropic anmelden“ nutzt dein Claude-Abo per CLI-OAuth (Claude-Code-Flow): Browser öffnet sich, du autorisierst, kopierst den angezeigten Code zurück. Alternativ klassisch per API-Key."
        case "openrouter":
            return "Anmelden per OAuth holt automatisch einen API-Key — oder eigenen Key einfügen. Keys liegen nur im Geräte-Keychain."
        case "openai":
            return "„Mit OpenAI anmelden“ nutzt dein ChatGPT-Abo per Codex-CLI-OAuth (Code kopieren). Hinweis: Abo-Tokens laufen über die Codex-/Responses-Schnittstelle — Chat funktioniert evtl. nicht mit jedem Modell. Sicher: API-Key oder GPT per OpenRouter."
        case "xai":
            return "„Mit xAI anmelden“ nutzt dein SuperGrok / X-Premium+-Abo per grok-cli-OAuth (Code kopieren) — läuft über den Grok-CLI-Proxy. Alternativ API-Key oder Grok per OpenRouter."
        case "sub2api":
            return "Base-URL deiner eigenen sub2api-Instanz eintragen (OpenAI-kompatibel, z. B. https://ki.meine-domain.de/v1) — so nutzt du Abo-Konten über dein selbst gehostetes Gateway."
        default:
            if settings.preset.editableBaseURL {
                return "Für eigene Server: Base-URL des kompatiblen Endpoints eintragen (Ollama, LM Studio, LocalAI, vLLM, LiteLLM …). Keys liegen nur im Geräte-Keychain."
            }
            return "Der API-Key wird nur im Geräte-Keychain gespeichert. Abo-Login (OAuth) bietet dieser Anbieter Dritt-Apps aktuell nicht öffentlich an."
        }
    }

    private func signInWithOAuth() {
        oauthError = nil
        guard let config = settings.preset.oauth else { return }
        if config.flow == .openRouterKeyExchange {
            let preset = settings.preset
            Task {
                do {
                    if case .apiKey(let key) = try await oauth.signInOpenRouter(preset: preset) {
                        Keychain.set(key, for: settings.keychainAccount)
                        apiKey = key
                    }
                } catch {
                    oauthError = error.localizedDescription
                }
            }
            return
        }
        // Paste-code CLI flow: open the browser, then collect the code.
        guard let pending = oauth.startPasteFlow(preset: settings.preset) else { return }
        UIApplication.shared.open(pending.authorizeURL)
        pendingPaste = pending
    }

    private func completePasteFlow(_ pending: OAuthService.PendingPaste, code: String) {
        oauthError = nil
        Task {
            do {
                if case .credential(let credential) = try await oauth.completePasteFlow(pending, pasted: code) {
                    AuthStore.save(credential, account: settings.keychainAccount)
                    oauthConnected = true
                    apiKey = ""
                    pendingPaste = nil
                }
            } catch {
                oauthError = error.localizedDescription
            }
        }
    }

    private func disconnectOAuth() {
        Keychain.set("", for: settings.keychainAccount)
        oauthConnected = false
        apiKey = ""
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
        } header: {
            Text("Modell")
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

    private func reloadKey() {
        oauthConnected = AuthStore.isOAuthConnected(account: settings.keychainAccount)
        apiKey = oauthConnected ? "" : Keychain.get(settings.keychainAccount)
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
