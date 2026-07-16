import SwiftUI

struct SettingsView: View {
    @State private var settings = ProviderSettings.load()
    @State private var apiKey = ""
    @StateObject private var modelStore = LocalModelStore()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Anbieter", selection: $settings.kind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    if settings.kind == .mlx {
                        localModelRows
                    } else {
                        TextField("Modell (z. B. claude-sonnet-5)", text: $settings.model)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField(
                            settings.kind == .openAICompatible
                                ? "Base-URL (z. B. http://mein-mac:11434/v1)"
                                : "Base-URL (leer = api.anthropic.com)",
                            text: $settings.baseURL
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        SecureField("API-Key", text: $apiKey)
                    }
                } header: {
                    Text("KI-Modell")
                } footer: {
                    if settings.kind == .mlx {
                        Text("Modelle laufen komplett auf dem Gerät (Apple MLX) — offline, privat, kostenlos. Download einmalig über WLAN empfohlen. Im Simulator nicht verfügbar.")
                    } else {
                        Text("Der Key wird nur im Geräte-Keychain gespeichert. Über „OpenAI-kompatibel“ + Base-URL laufen auch lokale Modelle (Ollama, LM Studio) auf deinem Rechner.")
                    }
                }

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
            .navigationTitle("Einstellungen")
            .onAppear {
                apiKey = Keychain.get(keyAccount)
            }
            .onChange(of: settings.kind) {
                apiKey = Keychain.get(keyAccount)
            }
            .onChange(of: settings) {
                settings.save()
            }
            .onChange(of: apiKey) {
                Keychain.set(apiKey, for: keyAccount)
            }
        }
    }

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

    private var keyAccount: String { "api-key-\(settings.kind.rawValue)" }
}
