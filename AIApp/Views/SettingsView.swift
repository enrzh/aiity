import SwiftUI

struct SettingsView: View {
    @State private var settings = ProviderSettings.load()
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Anbieter", selection: $settings.kind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
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
                } header: {
                    Text("KI-Modell")
                } footer: {
                    Text("Der Key wird nur im Geräte-Keychain gespeichert. Über „OpenAI-kompatibel“ + Base-URL laufen auch lokale Modelle (Ollama, LM Studio) auf deinem Rechner.")
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

    private var keyAccount: String { "api-key-\(settings.kind.rawValue)" }
}
