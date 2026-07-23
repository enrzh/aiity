import SwiftUI

/// App settings: provider entry + web search. Keep this screen short.
struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject private var prefs = AppPreferences.shared

    private var settings: Binding<ProviderSettings> { $settingsStore.settings }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ConnectionsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("KI-Anbieter & Modelle")
                                Text(activeLine)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "cpu")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .accessibilityIdentifier("open-connections")
                } footer: {
                    Text("Chat / Bild / Video getrennt. „Eigener Server“ für jede OpenAI-kompatible API.")
                }

                Section {
                    Toggle(isOn: $prefs.keepScreenAwakeWhileBuilding) {
                        Label("Bildschirm an während Build", systemImage: "sun.max.fill")
                    }
                    .accessibilityIdentifier("keep-screen-awake")
                } header: {
                    Text("Anzeige")
                } footer: {
                    Text("Wenn an: Display bleibt wach, solange Chat/Build läuft (kein Auto-Sperre). Aus = normaler Idle-Timer, spart Akku.")
                }

                Section {
                    Toggle(isOn: $prefs.allowLocalTools) {
                        Label("Web-Tools für lokale Modelle", systemImage: "globe.badge.chevron.backward")
                    }
                    .accessibilityIdentifier("allow-local-tools")
                } header: {
                    Text("Lokale Modelle")
                } footer: {
                    Text("Gibt On-Device- (MLX) und LAN-Modellen (Ollama/LM Studio) die Web-Suche. Nur für fähige Modelle (Qwen3 4B+) sinnvoll — kleine Modelle erfinden Tool-Aufrufe.")
                }

                Section {
                    Picker("Backend", selection: settings.searchBackend) {
                        ForEach(SearchBackend.allCases) { backend in
                            Text(backend.title).tag(backend.rawValue)
                        }
                    }
                    TextField("SearXNG-URL (optional)", text: settings.searchEndpoint)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("Brave Search API-Key", text: settings.searchBraveKey)
                        .textContentType(.password)
                        .onChange(of: settingsStore.settings.searchBraveKey) { _, v in
                            Keychain.set(v, for: "search-brave-key")
                        }
                    SecureField("Tavily API-Key", text: settings.searchTavilyKey)
                        .textContentType(.password)
                        .onChange(of: settingsStore.settings.searchTavilyKey) { _, v in
                            Keychain.set(v, for: "search-tavily-key")
                        }
                } header: {
                    Text("Web-Suche")
                } footer: {
                    Text("Auto wählt Tavily → Brave → SearXNG → DuckDuckGo. Keys von brave.com/search/api bzw. tavily.com. Nach der Suche holt der Agent per fetch_url den Seiteninhalt.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "—")
                } footer: {
                    Text("aiity — AI it yourself · com.aiity.app")
                }
            }
            .navigationTitle("Mehr")
        }
    }

    private var activeLine: String {
        let s = settingsStore.settings
        let model = s.effectiveModel
        if model.isEmpty { return "Aktiv: \(s.preset.label)" }
        let short = model.count > 32 ? String(model.prefix(30)) + "…" : model
        return "\(s.preset.label) · \(short)"
    }
}
