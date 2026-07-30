import SwiftUI

/// Pick the provider + model for one agent, as a pushed page rather than a
/// cramped inline picker and a free-text field.
///
/// Deliberately *not* `ConnectionsView`: that page switches the app-wide chat
/// provider. This one only writes back into the agent being edited, so opening
/// it can never change what the chat itself is talking to.
struct AgentModelPicker: View {
    @Binding var presetId: String
    @Binding var model: String

    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private var chatProviderLabel: String {
        ProviderPreset.preset(for: settingsStore.settings.presetId).label
    }

    var body: some View {
        List {
            Section {
                row(
                    title: "Wie der Chat",
                    subtitle: chatProviderLabel,
                    selected: presetId.isEmpty
                ) {
                    presetId = ""
                    model = ""
                    dismiss()
                }
            } footer: {
                Text("Der Agent nutzt denselben Anbieter wie der Chat. Änderst du den Chat-Anbieter, zieht der Agent mit.")
            }

            providerSection(
                ProviderPreset.catalog(maturity: .verified),
                header: "Getestet"
            )
            providerSection(
                ProviderPreset.catalog(maturity: .untested),
                header: "Weitere Anbieter"
            )
        }
        .navigationTitle("Modell")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func providerSection(_ presets: [ProviderPreset], header: String) -> some View {
        if !presets.isEmpty {
            Section(header) {
                ForEach(presets) { preset in
                    NavigationLink {
                        AgentModelList(
                            preset: preset,
                            presetId: $presetId,
                            model: $model
                        )
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.label)
                                if presetId == preset.id, !model.isEmpty {
                                    Text(model)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if presetId == preset.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .accessibilityIdentifier("agent-provider-option")
                }
            }
        }
    }

    private func row(
        title: String,
        subtitle: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .accessibilityIdentifier("agent-inherit-provider")
    }
}

/// Models available for one provider. Shows the cached/known list immediately
/// and refreshes from the provider in the background, so the page is never
/// empty while waiting on the network.
private struct AgentModelList: View {
    let preset: ProviderPreset
    @Binding var presetId: String
    @Binding var model: String

    @Environment(\.dismiss) private var dismiss
    @State private var models: [CatalogModel] = []
    @State private var custom = ""
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        List {
            if !models.isEmpty {
                Section {
                    ForEach(models) { entry in
                        Button {
                            choose(entry.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayName)
                                        .foregroundStyle(.primary)
                                    Text(entry.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if presetId == preset.id, model == entry.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .accessibilityIdentifier("agent-model-option")
                    }
                }
            }

            Section {
                TextField("Eigene Modell-ID", text: $custom)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("agent-custom-model")
                Button("Diese ID verwenden") {
                    choose(custom.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    Task { await refresh() }
                } label: {
                    if loading {
                        HStack { ProgressView().controlSize(.small); Text("Lädt…") }
                    } else {
                        Label("Modelle aktualisieren", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(loading)
            } footer: {
                if let loadError {
                    Text(loadError).foregroundStyle(.red)
                } else {
                    Text("Die Liste kommt aus dem Cache; „Aktualisieren“ holt sie live vom Anbieter.")
                }
            }
        }
        .navigationTitle(preset.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            models = ModelCatalogCache.modelsForDisplay(presetId: preset.id)
        }
    }

    private func choose(_ id: String) {
        guard !id.isEmpty else { return }
        presetId = preset.id
        model = id
        dismiss()
    }

    private func refresh() async {
        loading = true
        loadError = nil
        defer { loading = false }
        var settings = ProviderSettings.connectionSnapshot(presetId: preset.id)
        settings.presetId = preset.id
        let key = await AuthStore.effectiveKey(for: settings)
        do {
            models = try await ModelCatalogService.fetchModels(settings: settings, apiKey: key)
        } catch {
            loadError = NetworkErrorFriendly.message(for: error)
        }
    }
}
