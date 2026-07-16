import SwiftUI

struct SettingsView: View {
    @State private var settings = ProviderSettings.load()
    @State private var apiKey = ""
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
                skillsSection
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
            .onChange(of: apiKey) { Keychain.set(apiKey, for: settings.keychainAccount) }
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
                SecureField(settings.preset.needsKey ? "API-Key" : "API-Key (optional)", text: $apiKey)
                if settings.preset.oauthAvailable {
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
        switch settings.preset.dialect {
        case .mlx:
            return "Modelle laufen komplett auf dem Gerät (Apple MLX) — offline, privat, kostenlos. Download einmalig über WLAN empfohlen. Im Simulator nicht verfügbar."
        case .openai where settings.preset.oauthAvailable:
            return "Anmelden per OAuth holt automatisch einen API-Key — oder eigenen Key einfügen. Keys liegen nur im Geräte-Keychain."
        case .openai where settings.preset.editableBaseURL:
            return "Für eigene Server: Base-URL des OpenAI-kompatiblen Endpoints eintragen (Ollama, LM Studio, LocalAI, vLLM, LiteLLM …). Keys liegen nur im Geräte-Keychain."
        case .anthropic where settings.preset.editableBaseURL:
            return "Für eigene Server, die die Anthropic Messages API sprechen. Keys liegen nur im Geräte-Keychain."
        default:
            return "Der API-Key wird nur im Geräte-Keychain gespeichert. Abo-Login (OAuth) bietet dieser Anbieter Dritt-Apps aktuell nicht öffentlich an."
        }
    }

    private func signInWithOAuth() {
        oauthError = nil
        let preset = settings.preset
        Task {
            do {
                let key = try await oauth.signIn(preset: preset)
                apiKey = key
                Keychain.set(key, for: settings.keychainAccount)
            } catch {
                oauthError = error.localizedDescription
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
        } header: {
            Text("Modell")
        }
    }

    private func fetchModels() {
        fetchingModels = true
        modelsError = nil
        let snapshot = settings
        let key = apiKey
        Task {
            do {
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

    // MARK: Skills

    private var skillsSection: some View {
        Section {
            NavigationLink {
                SkillsView()
            } label: {
                Label("Agent-Skills", systemImage: "puzzlepiece.extension")
            }
        } footer: {
            Text("Skills sind installierbare Anleitungen, die den Agenten spezialisieren — z. B. besseres UI-Design, Spiele oder Diagramme.")
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
        apiKey = Keychain.get(settings.keychainAccount)
    }
}
