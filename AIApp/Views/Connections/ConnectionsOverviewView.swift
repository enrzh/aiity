import SwiftUI

/// Provider list grouped by chat, image, and video capability.
struct ConnectionsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var accountStore: AccountStore

    var body: some View {
        List {
            Section("Schnellstart") {
                quickLink("OpenRouter", icon: "globe", presetId: "openrouter")
                quickLink("Eigene API", icon: "link", presetId: "custom-openai")
                quickLink("Ollama", icon: "desktopcomputer", presetId: "ollama")
                quickLink("Gateway", icon: "server.rack", presetId: "sub2api")
            }

            modalitySection(.chat)
            modalitySection(.image)
            modalitySection(.video)
        }
        .navigationTitle("Anbieter")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func quickLink(
        _ title: String,
        icon: String,
        presetId: String
    ) -> some View {
        NavigationLink {
            ProviderConnectionView(presetId: presetId, modality: .chat)
        } label: {
            AppSettingsRow(title: title, systemImage: icon)
        }
    }

    @ViewBuilder
    private func modalitySection(_ modality: ModelModality) -> some View {
        let presets = providers(for: modality)
        let activeId = settingsStore.settings.activePresetId(for: modality)

        Section {
            if activeId.isEmpty {
                Text(emptySlotText(modality))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    ProviderConnectionView(presetId: activeId, modality: modality)
                } label: {
                    AppSettingsRow(
                        title: ProviderPreset.preset(for: activeId).label,
                        subtitle: activeSubtitle(modality: modality, presetId: activeId),
                        systemImage: modality.systemImage
                    )
                }
            }

            ForEach(presets.filter { $0.id != activeId }) { preset in
                NavigationLink {
                    ProviderConnectionView(presetId: preset.id, modality: modality)
                } label: {
                    AppSettingsRow(
                        title: preset.label,
                        subtitle: ProviderConnectionModel.statusText(
                            for: preset,
                            accountCount: accountStore.accounts(for: preset.id).count
                        )
                    ) {
                        if settingsStore.isActive(presetId: preset.id, for: modality) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel("Aktiv")
                        }
                    }
                }
            }
        } header: {
            Label(modality.sectionTitle, systemImage: modality.systemImage)
        }
    }

    private func providers(for modality: ModelModality) -> [ProviderPreset] {
        ProviderPreset.catalog.filter {
            MediaCapability.supports(modality, presetId: $0.id)
        }
    }

    private func emptySlotText(_ modality: ModelModality) -> String {
        switch modality {
        case .chat: return "Kein Chat-Anbieter"
        case .image: return "Kein Bild-Anbieter"
        case .video: return "Kein Video-Anbieter"
        }
    }

    private func activeSubtitle(
        modality: ModelModality,
        presetId: String
    ) -> String {
        let model = settingsStore.settings.model(for: modality)
        let modelPart = model.isEmpty ? "Kein Modell" : model
        if ProviderPreset.preset(for: presetId).dialect == .mlx {
            return "On-Device · \(modelPart)"
        }
        if let account = accountStore.activeAccount(for: presetId) {
            return "\(account.label) · \(modelPart)"
        }
        return "Kein Konto · \(modelPart)"
    }
}
