import SwiftUI

struct SettingsView: View {
    @State private var settings = ProviderSettings.load()
    @State private var apiKey = ""
    @State private var oauthClientId = ""
    @State private var oauthConnected = false
    @State private var availableModels: [String] = []
    @State private var modelsError: String?
    @State private var fetchingModels = false
    @State private var oauthError: String?
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
            .onChange(of: oauthClientId) { AuthStore.setClientId(oauthClientId, for: settings.presetId) }
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
                    if let config = settings.preset.oauth {
                        if config.needsClientId {
                            TextField("OAuth-Client-ID (aus der App-Registrierung)", text: $oauthClientId)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        Button {
                            signInWithOAuth()
                        } label: {
                            if oauth.busy {
                                ProgressView()
                            } else {
                                Label("Mit \(settings.preset.label.components(separatedBy: " ")[0]) anmelden", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                        .disabled(oauth.busy || (config.needsClientId && oauthClientId.trimmingCharacters(in: .whitespaces).isEmpty))
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
            return "„Sign in with Claude“ nutzt dein Claude-Abo (Abrechnung über Extra-Usage-Credits deines Kontos). Dafür einmalig eine App bei Anthropic registrieren und die Client-ID hier eintragen — Redirect-URI: aiapp://oauth/anthropic. Alternativ klassisch per API-Key."
        case "openrouter":
            return "Anmelden per OAuth holt automatisch einen API-Key — oder eigenen Key einfügen. Keys liegen nur im Geräte-Keychain."
        case "openai":
            return "OpenAI bietet „Sign in with ChatGPT“ Dritt-Apps bis heute nicht für Modell-Nutzung an — es gibt keinen OAuth-Endpoint, der einen Key auf dein Abo bucht (nur SSO + GPT-Actions). Daher API-Key oder GPT-Modelle per OpenRouter-Login."
        case "xai":
            return "Grok hat seit 05/2026 einen Abo-Login (SuperGrok / X Premium+) per Device-Code gegen accounts.x.ai — den nutzen Partner-Apps mit eigener Client-ID. Eine öffentliche Registrierung für beliebige Apps gibt es nicht, deshalb hier API-Key oder Grok per OpenRouter-Login."
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
        let preset = settings.preset
        let clientId = oauthClientId.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                switch try await oauth.signIn(preset: preset, clientId: clientId) {
                case .apiKey(let key):
                    Keychain.set(key, for: settings.keychainAccount)
                    apiKey = key
                case .credential(let credential):
                    AuthStore.save(credential, account: settings.keychainAccount)
                    oauthConnected = true
                    apiKey = ""
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
        oauthConnected = AuthStore.storedOAuthCredential(account: settings.keychainAccount) != nil
        apiKey = oauthConnected ? "" : Keychain.get(settings.keychainAccount)
        oauthClientId = AuthStore.clientId(for: settings.presetId)
    }
}
