import SwiftUI

/// Provider list grouped by chat and image capability.
struct ConnectionsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var accountStore: AccountStore
    @State private var connectRoute: OnboardingConnectRoute?

    var body: some View {
        List {
            // Leads with the paths we have actually run end to end.
            Section {
                quickLink("OpenRouter", icon: "globe", presetId: "openrouter")
                quickLink("Gateway (sub2api)", icon: "server.rack", presetId: "sub2api")
                quickLink(String(localized: "Auf dem Gerät"), icon: "iphone", presetId: "mlx")
                quickLink("Eigene API", icon: "link", presetId: "custom-openai")
                quickLink("Ollama", icon: "desktopcomputer", presetId: "ollama")
            } header: {
                Text("Schnellstart")
            }

            Section {
                NavigationLink {
                    ProviderConnectionView(presetId: "apple-foundation", modality: .chat)
                } label: {
                    AppSettingsRow(
                        title: "Apple Foundation Models",
                        subtitle: ProviderConnectionModel.statusText(
                            for: ProviderPreset.preset(for: "apple-foundation"),
                            accountCount: 0
                        ),
                        systemImage: "apple.intelligence"
                    )
                }
            } header: {
                Text("Apple Intelligence")
            }

            modalitySection(.chat)
            modalitySection(.image)
        }
        .navigationTitle("Anbieter")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $connectRoute) { route in
            NavigationStack {
                switch route {
                case .preset(let presetId):
                    ProviderConnectionView(presetId: presetId, modality: .chat)
                case .modalityPreset(let presetId, let modality):
                    ProviderConnectionView(presetId: presetId, modality: modality)
                case .modalityPicker(let modality):
                    ProviderPickerList(
                        title: modality.sectionTitle,
                        presetIds: ProviderPreset.catalog
                            .filter { MediaCapability.supports(modality, presetId: $0.id) }
                            .map(\.id)
                    ) { presetId in
                        connectRoute = .modalityPreset(presetId, modality)
                    }
                case .apiKeyPicker, .localPicker:
                    EmptyView()
                }
            }
            .environmentObject(settingsStore)
            .environmentObject(accountStore)
        }
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
        let activeId = settingsStore.settings.activePresetId(for: modality)
        let others = providers(for: modality).filter { $0.id != activeId }

        Section {
            if activeId.isEmpty {
                Button {
                    connectRoute = .modalityPicker(modality)
                } label: {
                    Label(emptySlotText(modality), systemImage: "plus.circle")
                }
                .accessibilityIdentifier("connect-\(modality.rawValue)")
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

            ForEach(others.filter(\.isVerified)) { preset in
                providerRow(preset, modality: modality)
            }
        } header: {
            Label(modality.sectionTitle, systemImage: modality.systemImage)
        }

        // Same code path as the tested ones — we just haven't run a request
        // through them, and a picker that hides that difference is lying.
        let untested = others.filter { !$0.isVerified }
        if !untested.isEmpty {
            Section {
                ForEach(untested) { preset in
                    providerRow(preset, modality: modality)
                }
            } header: {
                Text("\(modality.sectionTitle) — weitere Anbieter")
            } footer: {
                Text("Gleiche Technik wie oben, von uns aber nicht getestet. Funktionieren normalerweise — mit „Verbindung testen“ prüfen.")
            }
        }
    }

    private func providerRow(_ preset: ProviderPreset, modality: ModelModality) -> some View {
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

    private func providers(for modality: ModelModality) -> [ProviderPreset] {
        ProviderPreset.catalog.filter {
            $0.id != "apple-foundation"
                && MediaCapability.supports(modality, presetId: $0.id)
        }
    }

    private func emptySlotText(_ modality: ModelModality) -> String {
        switch modality {
        case .chat: return String(localized: "Kein Chat-Anbieter")
        case .image: return String(localized: "Kein Bild-Anbieter")
        }
    }

    private func activeSubtitle(
        modality: ModelModality,
        presetId: String
    ) -> String {
        let model = settingsStore.settings.model(for: modality)
        let modelPart = model.isEmpty ? "Kein Modell" : model
        if [.mlx, .foundation].contains(ProviderPreset.preset(for: presetId).dialect) {
            return "On-Device · \(modelPart)"
        }
        if let account = accountStore.activeAccount(for: presetId) {
            return "\(account.label) · \(modelPart)"
        }
        return "Kein Konto · \(modelPart)"
    }
}
