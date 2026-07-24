import SwiftUI
import UIKit

/// Provider list separated by modality: Chat, Image, Video. Each section has
/// its own active provider+model. Accounts are shared per provider; media is
/// never configured as nested fields inside a chat provider.
struct ConnectionsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var accountStore: AccountStore

    var body: some View {
        List {
            Section {
                Text("OpenRouter = hunderte Modelle mit einem Key. „Eigener Server“ = jede OpenAI-kompatible API (LiteLLM, vLLM, Azure, …). Ollama/LM Studio für den Heimserver.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    ProviderConnectionView(presetId: "openrouter", modality: .chat)
                } label: {
                    Label("OpenRouter (alle Modelle)", systemImage: "globe")
                }
                NavigationLink {
                    ProviderConnectionView(presetId: "custom-openai", modality: .chat)
                } label: {
                    Label("Beliebige OpenAI-API (URL + Key)", systemImage: "link")
                }
                NavigationLink {
                    ProviderConnectionView(presetId: "ollama", modality: .chat)
                } label: {
                    Label("Ollama / lokal", systemImage: "desktopcomputer")
                }
            } header: {
                Text("Schnellstart")
            }

            modalitySection(.chat)
            modalitySection(.image)
            modalitySection(.video)
        }
        .navigationTitle("Anbieter")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func modalitySection(_ modality: ModelModality) -> some View {
        let presets = providers(for: modality)
        let activeId = settingsStore.settings.activePresetId(for: modality)

        Section {
            // Active slot summary
            if activeId.isEmpty {
                Text(emptySlotText(modality))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    ProviderConnectionView(presetId: activeId, modality: modality)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: modality.systemImage)
                            .foregroundStyle(Color.accentColor)
                            .font(.title3)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ProviderPreset.preset(for: activeId).label)
                                .font(.headline)
                            Text(activeSubtitle(modality: modality, presetId: activeId))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            ForEach(presets.filter { $0.id != activeId }) { preset in
                providerRow(preset, modality: modality)
            }
        } header: {
            Label(modality.sectionTitle, systemImage: modality.systemImage)
        } footer: {
            Text(footer(for: modality))
        }
    }

    private func providers(for modality: ModelModality) -> [ProviderPreset] {
        ProviderPreset.catalog.filter { MediaCapability.supports(modality, presetId: $0.id) }
    }

    private func emptySlotText(_ modality: ModelModality) -> String {
        switch modality {
        case .chat: return "Noch kein Chat-Anbieter gewählt"
        case .image: return "Kein Bild-Anbieter — unten einen wählen"
        case .video: return "Kein Video-Anbieter — unten einen wählen"
        }
    }

    private func footer(for modality: ModelModality) -> String {
        switch modality {
        case .chat:
            return "Der Chat nutzt diesen Anbieter und das Chat-Modell. Tippe einen Anbieter an, um Konten und Modell zu verwalten."
        case .image:
            return "Unabhängig vom Chat. generate_image nutzt diesen Anbieter und das Bild-Modell."
        case .video:
            return "Unabhängig vom Chat. generate_video nutzt diesen Anbieter und das Video-Modell."
        }
    }

    private func activeSubtitle(modality: ModelModality, presetId: String) -> String {
        let model = settingsStore.settings.model(for: modality)
        let modelPart = model.isEmpty ? "Kein Modell" : model
        if ProviderPreset.preset(for: presetId).dialect == .mlx {
            return "On-Device · \(modelPart)"
        }
        if let account = accountStore.activeAccount(for: presetId) {
            let kind = account.isOAuth ? "Abo" : "API-Key"
            return "\(account.label) · \(kind) · \(modelPart)"
        }
        return "Kein Konto · \(modelPart)"
    }

    private func providerRow(_ preset: ProviderPreset, modality: ModelModality) -> some View {
        NavigationLink {
            ProviderConnectionView(presetId: preset.id, modality: modality)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.label)
                    Text(statusText(for: preset)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if settingsStore.isActive(presetId: preset.id, for: modality) {
                    Text("Aktiv")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func statusText(for preset: ProviderPreset) -> String {
        if preset.dialect == .mlx { return "On-Device (MLX)" }
        switch accountStore.accounts(for: preset.id).count {
        case 0:
            // Subscription (paste-code) OAuth is experimental for third-party
            // apps; present the API key as the primary, recommended path.
            if preset.oauth?.flow == .pasteCode { return "API-Key (empfohlen) · Abo-Login möglich" }
            return preset.oauthAvailable ? "API-Key oder Abo-Login" : "API-Key"
        case 1: return "1 Konto"
        case let count: return "\(count) Konten"
        }
    }
}

/// Manages one provider for a given modality: accounts (shared), and the model
/// for that modality only. No nested image/video fields on chat.
struct ProviderConnectionView: View {
    let presetId: String
    var modality: ModelModality = .chat

    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var accountStore: AccountStore
    @StateObject private var oauth = OAuthService()
    @StateObject private var modelStore = LocalModelStore()

    @State private var newKey = ""
    @State private var newLabel = ""
    @State private var authError: String?
    @State private var pendingPaste: OAuthService.PendingPaste?
    @State private var catalogModels: [CatalogModel] = []
    @State private var modelsError: String?
    @State private var fetchingModels = false
    @State private var probing = false
    @State private var probeResult: ConnectionProbeResult?
    @State private var hostDraft = ""
    /// Local draft for model when this provider is not yet the active slot.
    @State private var modelDraft = ""

    private var preset: ProviderPreset { ProviderPreset.preset(for: presetId) }
    private var isLocalWizard: Bool { ConnectionProbe.isLocalStyle(presetId) }
    private var isActiveForModality: Bool {
        settingsStore.isActive(presetId: presetId, for: modality)
    }
    private var isChatActive: Bool { settingsStore.settings.presetId == presetId }
    private var accounts: [Account] { accountStore.accounts(for: presetId) }
    private var activeAccount: Account? { accountStore.activeAccount(for: presetId) }
    private var availableModelIds: [String] { catalogModels.map(\.id) }
    private var isOpenAIOAuth: Bool {
        presetId == "openai" && (activeAccount?.isOAuth == true)
    }

    /// Connection settings for this preset (chat-active uses live store; else profile).
    private var connectionSettings: ProviderSettings {
        if isChatActive {
            return settingsStore.settings
        }
        return ProviderSettings.connectionSnapshot(presetId: presetId)
    }

    var body: some View {
        Form {
            useForModalitySection
            if preset.dialect == .mlx {
                if modality == .chat {
                    Section("Modelle auf dem Gerät") { localModelRows }
                    if isActiveForModality { testConnectionSection }
                } else {
                    Section {
                        Text("On-Device MLX unterstützt nur Chat, keine Bild-/Videogenerierung.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                if (isChatActive || modality != .chat) && preset.editableBaseURL {
                    if isLocalWizard { localRuntimeWizardSection } else { baseURLSection }
                }
                accountsSection
                if modality == .chat && isChatActive && presetId == "openai" {
                    openAIPathSection
                }
                if supportsThisModality {
                    modelSection
                    if isActiveForModality || modality == .chat {
                        testConnectionSection
                    }
                }
            }
            Section { Text(footer).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(preset.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            syncDraftsFromStore()
            // Instant model list from cache/defaults, then silent refresh.
            bootstrapModels()
        }
        .sheet(item: $pendingPaste) { pending in
            AppSheet(detents: [.large, .medium]) {
                PasteCodeSheet(
                    providerLabel: preset.label,
                    busy: oauth.busy,
                    hint: oauthPasteHint,
                    onCancel: { pendingPaste = nil },
                    onSubmit: { completePasteFlow(pending, code: $0) }
                )
            }
        }
    }

    private var oauthPasteHint: String {
        if presetId == "openai" {
            return "Browser öffnet ChatGPT-Login. Nach Freigabe erscheint oft eine leere Seite oder localhost-URL — kopiere den gesamten Code (oder die URL mit ?code=…) und füge ihn hier ein. Danach stehen Codex-Modelle sofort bereit."
        }
        if presetId == "anthropic" {
            return "Nach der Autorisierung den angezeigten Code (manchmal als code#state) hier einfügen."
        }
        return "Autorisierungscode oder Callback-URL hier einfügen."
    }

    private var supportsThisModality: Bool {
        MediaCapability.supports(modality, presetId: presetId)
    }

    private func syncDraftsFromStore() {
        let snap = connectionSettings
        if hostDraft.isEmpty {
            hostDraft = snap.baseURL.isEmpty ? preset.defaultBaseURL : snap.baseURL
        }
        if isActiveForModality {
            modelDraft = settingsStore.settings.model(for: modality)
            if modality == .chat, modelDraft.isEmpty {
                modelDraft = settingsStore.settings.model
            }
        } else {
            let profile = ProviderProfiles.profile(for: presetId)
            switch modality {
            case .chat:
                modelDraft = profile.model.isEmpty ? preset.defaultModel : profile.model
            case .image:
                modelDraft = profile.lastImageModel.isEmpty
                    ? ModelModality.image.defaultModel : profile.lastImageModel
            case .video:
                modelDraft = profile.lastVideoModel.isEmpty
                    ? ModelModality.video.defaultModel : profile.lastVideoModel
            }
        }
    }

    // MARK: Use for modality

    private var useForModalitySection: some View {
        Section {
            if isActiveForModality {
                Label(modality.activeLabel, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            } else {
                Button {
                    applyAsActive()
                } label: {
                    Label(modality.useButtonTitle, systemImage: modality.systemImage)
                }
            }
            // Cross-links: allow assigning the same connected provider to other slots.
            if modality != .chat, MediaCapability.supports(.chat, presetId: presetId), !isChatActive {
                Button {
                    settingsStore.useForChat(presetId)
                } label: {
                    Label(ModelModality.chat.useButtonTitle, systemImage: ModelModality.chat.systemImage)
                }
            }
            if modality == .chat {
                if MediaCapability.supportsImageGeneration(presetId: presetId),
                   settingsStore.settings.imagePresetId != presetId {
                    Button {
                        settingsStore.useForImage(presetId)
                    } label: {
                        Label(ModelModality.image.useButtonTitle, systemImage: ModelModality.image.systemImage)
                    }
                }
                if MediaCapability.supportsVideoGeneration(presetId: presetId),
                   settingsStore.settings.videoPresetId != presetId {
                    Button {
                        settingsStore.useForVideo(presetId)
                    } label: {
                        Label(ModelModality.video.useButtonTitle, systemImage: ModelModality.video.systemImage)
                    }
                }
            }
        } header: {
            Text(modality.sectionTitle)
        } footer: {
            if modality == .chat {
                Text("Konten gelten für alle Nutzungsarten dieses Anbieters. Bild- und Video-Modelle werden in den Abschnitten Bild / Video gewählt.")
            }
        }
    }

    private func applyAsActive() {
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Persist base URL into profile (and chat settings if chat-active).
        persistBaseURLIfNeeded()
        settingsStore.use(for: modality, presetId: presetId, model: model.isEmpty ? nil : model)
        if modality == .chat, isLocalWizard, !hostDraft.isEmpty {
            settingsStore.settings.baseURL = hostDraft
        }
    }

    private func persistBaseURLIfNeeded() {
        guard preset.editableBaseURL else { return }
        let url = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        ProviderProfiles.update(presetId: presetId) { $0.baseURL = url }
        if isChatActive {
            settingsStore.settings.baseURL = url
        }
    }

    // MARK: Base URL

    private var baseURLSection: some View {
        Section {
            TextField(
                preset.defaultBaseURL.isEmpty
                    ? "Server-Adresse (z. B. ki.meine-domain.de)"
                    : "Base-URL (Standard: \(preset.defaultBaseURL))",
                text: $hostDraft
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .onChange(of: hostDraft) { _, newValue in
                ProviderProfiles.update(presetId: presetId) { $0.baseURL = newValue }
                if isChatActive {
                    settingsStore.settings.baseURL = newValue
                }
            }
            let effective = connectionSettings.effectiveBaseURL
            if !hostDraft.isEmpty, effective != hostDraft {
                Text("→ \(effective)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Server")
        }
    }

    private var localRuntimeWizardSection: some View {
        Section {
            TextField(
                presetId == "ollama"
                    ? "Host (z. B. http://192.168.1.10:11434)"
                    : (preset.defaultBaseURL.isEmpty
                       ? "http://IP:Port oder http://Mac.local:1234"
                       : "Base-URL (Standard: \(preset.defaultBaseURL))"),
                text: $hostDraft
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .onChange(of: hostDraft) { _, newValue in
                ProviderProfiles.update(presetId: presetId) { $0.baseURL = newValue }
                if isChatActive {
                    settingsStore.settings.baseURL = newValue
                }
            }
            if !hostDraft.isEmpty {
                Text("→ \(connectionSettings.effectiveBaseURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if presetId == "ollama" {
                Text("Ollama auf dem Mac: `ollama serve`, dann die LAN-IP dieses Macs hier eintragen (nicht localhost vom iPhone).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Lokaler Runtime-Server")
        } footer: {
            Text("Geführtes Setup für Ollama, LM Studio, LocalAI und OpenAI-kompatible Server. Danach „Verbindung testen“.")
        }
    }

    private var testConnectionSection: some View {
        Section {
            Button {
                runProbe()
            } label: {
                if probing {
                    ProgressView()
                } else {
                    Label("Verbindung testen", systemImage: "stethoscope")
                }
            }
            .disabled(probing)
            .accessibilityIdentifier("test-connection")
            if let probeResult {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: probeResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(probeResult.ok ? Color.green : Color.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(probeResult.reason)
                            .font(.footnote)
                        if !probeResult.models.isEmpty {
                            Text(probeResult.models.prefix(8).joined(separator: ", ")
                                 + (probeResult.models.count > 8 ? " …" : ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if probeResult.ok && probeResult.chatOnly {
                            Text("Mini-Apps: Template-Modus (nicht freies Pro-HTML).")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Diagnose")
        } footer: {
            Text("Lädt die Modell-Liste und sendet einen kurzen Test-Chat. Fehler werden klar angezeigt — kein stilles Scheitern.")
        }
    }

    // MARK: Accounts

    private var accountsSection: some View {
        Section {
            ForEach(accounts) { account in
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

            if preset.needsKey || preset.editableBaseURL {
                SecureField("Neuer API-Key", text: $newKey)
                if !newKey.isEmpty {
                    TextField("Bezeichnung (optional, z. B. „Privat“)", text: $newLabel)
                        .autocorrectionDisabled()
                    Button {
                        accountStore.addKeyAccount(presetId: presetId, label: newLabel, key: newKey)
                        newKey = ""; newLabel = ""
                    } label: {
                        Label("Key als Konto hinzufügen", systemImage: "plus.circle")
                    }
                }
            }
            if preset.oauth != nil {
                Button {
                    signInWithOAuth()
                } label: {
                    if oauth.busy {
                        ProgressView()
                    } else {
                        Label(oauthButtonTitle, systemImage: "person.crop.circle.badge.plus")
                    }
                }
                .disabled(oauth.busy)
                .accessibilityIdentifier("oauth-add-account")
            }
            // Honest steer: consumer-subscription OAuth is not an officially
            // supported third-party path — recommend a pay-as-you-go API key.
            // (OpenRouter's key-exchange OAuth is legit, so it is excluded.)
            if preset.oauth?.flow == .pasteCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Abo-Login (ChatGPT-/Claude-/Grok-Abo) ist für Dritt-Apps nicht offiziell unterstützt und kann jederzeit eingeschränkt werden. Zuverlässig und empfohlen: ein eigener API-Key (Pay-as-you-go).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let url = apiKeyURL {
                        Link(apiKeyLinkTitle, destination: url)
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(.vertical, 2)
            }
            if let authError {
                Text(authError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Konten")
        } footer: {
            Text(accounts.isEmpty
                 ? "Noch kein Konto — am besten einen API-Key eintragen (Pay-as-you-go)."
                 : "Mehrere Konten möglich; das angehakte gilt für alle Nutzungsarten dieses Anbieters.")
        }
    }

    private var oauthVerb: String {
        preset.label.components(separatedBy: " ").first ?? preset.label
    }

    /// Provider-specific sign-in verb (avoids awkward "Konto per xAI hinzufügen").
    private var oauthButtonTitle: String {
        switch presetId {
        case "openai": return "Mit ChatGPT-Abo anmelden"
        case "anthropic": return "Mit Claude-Abo anmelden"
        case "xai": return "Mit Grok-Abo anmelden"
        case "openrouter": return "Mit OpenRouter anmelden"
        default: return "Konto per \(oauthVerb) hinzufügen"
        }
    }

    /// Where to get a pay-as-you-go API key for the recommended path.
    private var apiKeyURL: URL? {
        switch presetId {
        case "openai": return URL(string: "https://platform.openai.com/api-keys")
        case "anthropic": return URL(string: "https://console.anthropic.com/settings/keys")
        case "xai": return URL(string: "https://console.x.ai")
        default: return nil
        }
    }

    private var apiKeyLinkTitle: String {
        switch presetId {
        case "openai": return "API-Key erstellen (platform.openai.com)"
        case "anthropic": return "API-Key erstellen (console.anthropic.com)"
        case "xai": return "API-Key erstellen (console.x.ai)"
        default: return "API-Key erstellen"
        }
    }

    // MARK: OpenAI path

    private var openAIPathSection: some View {
        Section {
            if isOpenAIOAuth {
                Label {
                    Text("ChatGPT-Abo (Codex): experimentell und für Dritt-Apps nicht garantiert — kann jederzeit abgewiesen werden. Zuverlässig ist ein API-Key-Konto (platform.openai.com/api-keys). Bild/Video brauchen ohnehin einen API-Key.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                Label {
                    Text("API-Key — Standard Chat Completions (api.openai.com). Nach „Modelle laden“ ein verfügbares Modell wählen.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "key.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        } header: {
            Text("OpenAI-Pfad")
        }
    }

    // MARK: Model for this modality only

    private var modelSection: some View {
        Section {
            if catalogModels.isEmpty {
                TextField(
                    modelPlaceholder,
                    text: Binding(
                        get: { modelDraft },
                        set: { newValue in
                            modelDraft = newValue
                            commitModel(newValue)
                        }
                    )
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            } else {
                Picker(modality.modelSectionTitle, selection: Binding(
                    get: { modelDraft },
                    set: { newValue in
                        modelDraft = newValue
                        commitModel(newValue)
                    }
                )) {
                    if !modelDraft.isEmpty && !availableModelIds.contains(modelDraft) {
                        Text("\(modelDraft) (nicht in Liste)")
                            .tag(modelDraft)
                    }
                    ForEach(filteredCatalogModels) { model in
                        VStack(alignment: .leading) {
                            Text(model.displayName)
                            Text(model.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(model.id)
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
                    Label(
                        catalogModels.isEmpty
                            ? "Modelle laden"
                            : "Modelle aktualisieren (\(filteredCatalogModels.count))",
                        systemImage: "arrow.clockwise"
                    )
                }
            }
            .disabled(fetchingModels)
            .accessibilityIdentifier("fetch-models")
            if let err = modelsError {
                BannerView(message: err, kind: .error) {
                    self.modelsError = nil
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        } header: {
            Text(modality.modelSectionTitle)
        } footer: {
            Text(modelFooter)
        }
    }

    private var modelPlaceholder: String {
        switch modality {
        case .chat:
            return preset.defaultModel.isEmpty ? "Modell-ID" : "Modell (Standard: \(preset.defaultModel))"
        case .image:
            return "Bild-Modell (z. B. gpt-image-1)"
        case .video:
            return "Video-Modell (z. B. sora-2)"
        }
    }

    /// Prefer generative ids for image/video pickers when the catalog is rich.
    private var filteredCatalogModels: [CatalogModel] {
        switch modality {
        case .chat:
            // Keep specialised embedding/audio/image/moderation ids out of the
            // chat picker (OpenAI's /models returns the whole account catalog).
            let chat = catalogModels.filter { ModelCatalogService.isLikelyChatModel(id: $0.id) }
            return chat.isEmpty ? catalogModels : chat
        case .image:
            let gen = catalogModels.filter {
                MediaCapability.modelLooksGenerative(id: $0.id.lowercased())
                    || $0.id.lowercased().contains("dall")
                    || $0.id.lowercased().contains("flux")
                    || $0.id.lowercased().contains("imagen")
            }
            return gen.isEmpty ? catalogModels : gen
        case .video:
            let gen = catalogModels.filter {
                $0.id.lowercased().contains("sora")
                    || $0.id.lowercased().contains("video")
                    || MediaCapability.modelLooksGenerative(id: $0.id.lowercased())
            }
            return gen.isEmpty ? catalogModels : gen
        }
    }

    private var modelFooter: String {
        switch modality {
        case .chat:
            if isOpenAIOAuth {
                return "ChatGPT-Abo nutzt Codex-Modelle (Liste vorinstalliert). Kein api.openai.com/models — bei Fehlern anderes Codex-Modell wählen oder API-Key-Konto."
            }
            if isLocalWizard {
                return "Liste erscheint sofort aus Cache; „Aktualisieren“ holt frische Modelle vom Server."
            }
            return "Modelle sind vorab geladen (Cache/Standard). „Aktualisieren“ holt die Live-Liste vom Anbieter."
        case .image:
            return "Nur das Bild-Modell für generate_image. Unabhängig vom Chat-Modell."
        case .video:
            return "Nur das Video-Modell für generate_video. Unabhängig vom Chat-Modell."
        }
    }

    /// Show cached/default models immediately; refresh from network without blocking UI.
    private func bootstrapModels() {
        let seed = ModelCatalogCache.modelsForDisplay(presetId: presetId)
        // OpenAI OAuth: always show Codex curated list (never empty).
        if isOpenAIOAuth || (presetId == "openai" && activeAccount?.isOAuth == true) {
            catalogModels = ModelCatalogCache.codexOAuthModels()
            if modelDraft.isEmpty, let first = catalogModels.first {
                modelDraft = first.id
                commitModel(first.id)
            }
            return
        }
        if !seed.isEmpty {
            catalogModels = seed
            if modelDraft.isEmpty || !seed.map(\.id).contains(modelDraft) {
                if let pick = ModelCatalogService.autoPickModel(
                    from: seed,
                    settings: connectionSettings
                ) {
                    modelDraft = pick
                    // Don't force-commit empty active slot without user intent for non-active.
                    if isActiveForModality || isChatActive {
                        commitModel(pick)
                    }
                }
            }
        }
        // Background refresh when we have credentials or local server.
        let hasAccount = !accounts.isEmpty || preset.dialect == .mlx || !preset.needsKey
        if hasAccount {
            silentRefreshModels()
        }
    }

    private func silentRefreshModels() {
        let snapshot = probeSnapshot()
        Task {
            let key = await AuthStore.effectiveKey(for: snapshot)
            // Skip network noise if cloud needs key and none present.
            if snapshot.preset.needsKey && key.isEmpty && snapshot.preset.dialect != .mlx {
                return
            }
            if let models = try? await ModelCatalogService.fetchModels(settings: snapshot, apiKey: key),
               !models.isEmpty {
                await MainActor.run {
                    catalogModels = models
                    if modelDraft.isEmpty,
                       let pick = ModelCatalogService.autoPickModel(from: models, settings: snapshot) {
                        modelDraft = pick
                        if isActiveForModality || isChatActive {
                            commitModel(pick)
                        }
                    }
                }
            }
        }
    }

    private func commitModel(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch modality {
        case .chat:
            ProviderProfiles.update(presetId: presetId) { $0.model = trimmed }
            if isChatActive {
                settingsStore.settings.model = trimmed
            }
        case .image:
            ProviderProfiles.update(presetId: presetId) { $0.lastImageModel = trimmed }
            if isActiveForModality {
                settingsStore.settings.imageModel = trimmed
            }
        case .video:
            ProviderProfiles.update(presetId: presetId) { $0.lastVideoModel = trimmed }
            if isActiveForModality {
                settingsStore.settings.videoModel = trimmed
            }
        }
    }

    // MARK: On-device (MLX)

    @ViewBuilder
    private var localModelRows: some View {
        ForEach(LocalModel.catalog) { model in
            HStack(spacing: 12) {
                Button {
                    settingsStore.settings.localModelId = model.id
                } label: {
                    HStack {
                        Image(systemName: settingsStore.settings.localModelId == model.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(settingsStore.settings.localModelId == model.id ? Color.accentColor : Color.secondary)
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

    // MARK: Actions

    private func signInWithOAuth() {
        authError = nil
        guard let config = preset.oauth else { return }
        if config.flow == .openRouterKeyExchange {
            Task {
                do {
                    if case .apiKey(let key) = try await oauth.signInOpenRouter(preset: preset) {
                        accountStore.addKeyAccount(presetId: presetId, label: "OpenRouter", key: key)
                    }
                } catch {
                    authError = error.localizedDescription
                }
            }
            return
        }
        guard let pending = oauth.startPasteFlow(preset: preset) else { return }
        UIApplication.shared.open(pending.authorizeURL)
        pendingPaste = pending
    }

    private func completePasteFlow(_ pending: OAuthService.PendingPaste, code: String) {
        authError = nil
        let label = oauthVerb
        Task {
            do {
                if case .credential(let credential) = try await oauth.completePasteFlow(pending, pasted: code) {
                    accountStore.addOAuthAccount(presetId: presetId, label: label, credential: credential)
                    pendingPaste = nil
                    // Immediately surface models (Codex curated or live list).
                    if presetId == "openai" {
                        catalogModels = ModelCatalogCache.codexOAuthModels()
                        ModelCatalogCache.save(presetId: presetId, models: catalogModels)
                        if let first = catalogModels.first {
                            modelDraft = first.id
                            commitModel(first.id)
                        }
                        if !isChatActive { settingsStore.useForChat(presetId) }
                    } else {
                        bootstrapModels()
                    }
                }
            } catch {
                authError = NetworkErrorFriendly.message(for: error)
                    + (presetId == "openai"
                       ? " — Tipp: gesamten Callback-Link mit code= einfügen, Code muss frisch sein (einmalig)."
                       : "")
            }
        }
    }

    private func probeSnapshot() -> ProviderSettings {
        persistBaseURLIfNeeded()
        var snap = connectionSettings
        if isLocalWizard || preset.editableBaseURL, !hostDraft.isEmpty {
            snap.baseURL = hostDraft
        }
        // Ensure probe uses this preset even when not chat-active.
        snap.presetId = presetId
        if modality == .chat, !modelDraft.isEmpty {
            snap.model = modelDraft
        }
        return snap
    }

    private func fetchModels() {
        fetchingModels = true
        modelsError = nil
        // For chat, activate so catalog + auto-pick land on live settings.
        if modality == .chat, !isChatActive {
            applyAsActive()
        }
        var snapshot = probeSnapshot()
        Task {
            do {
                let key = await AuthStore.effectiveKey(for: snapshot)
                // Ensure OAuth OpenAI snapshot still uses openai presetId for curated path.
                snapshot.presetId = presetId
                let models = try await ModelCatalogService.fetchModels(settings: snapshot, apiKey: key)
                catalogModels = models
                if models.isEmpty {
                    modelsError = "Keine Modelle gemeldet."
                } else {
                    let pickPool = filteredCatalogModels.isEmpty ? models : filteredCatalogModels
                    if modality == .chat {
                        if let pick = ModelCatalogService.autoPickModel(from: pickPool, settings: snapshot) {
                            modelDraft = pick
                            commitModel(pick)
                        }
                    } else if modelDraft.isEmpty || !pickPool.map(\.id).contains(modelDraft) {
                        if let first = pickPool.first {
                            modelDraft = first.id
                            commitModel(first.id)
                        }
                    }
                    // Ensure modality slot is active after successful load.
                    if !isActiveForModality {
                        applyAsActive()
                    }
                }
            } catch {
                modelsError = NetworkErrorFriendly.message(for: error)
                // Keep showing defaults if we have them.
                if catalogModels.isEmpty {
                    catalogModels = ModelCatalogCache.modelsForDisplay(presetId: presetId)
                }
            }
            fetchingModels = false
        }
    }

    private func runProbe() {
        probing = true
        probeResult = nil
        if modality == .chat, !isChatActive {
            applyAsActive()
        }
        let snapshot = probeSnapshot()
        Task {
            let key = await AuthStore.effectiveKey(for: snapshot)
            let result = await ConnectionProbe.test(settings: snapshot, apiKey: key)
            probeResult = result
            if result.ok, !result.models.isEmpty {
                if let rich = try? await ModelCatalogService.fetchModels(settings: snapshot, apiKey: key) {
                    catalogModels = rich
                    if modality == .chat,
                       let pick = ModelCatalogService.autoPickModel(from: rich, settings: snapshot) {
                        modelDraft = pick
                        commitModel(pick)
                    }
                } else {
                    catalogModels = result.models.map { CatalogModel(id: $0) }
                    if modality == .chat,
                       let pick = ModelCatalogService.autoPickModel(from: catalogModels, settings: snapshot) {
                        modelDraft = pick
                        commitModel(pick)
                    }
                }
            }
            probing = false
        }
    }

    private var footer: String {
        switch presetId {
        case "mlx":
            return "Modelle laufen komplett auf dem Gerät (Apple MLX) — offline, privat, kostenlos. Download einmalig über WLAN empfohlen. Im Simulator nicht verfügbar."
        case "anthropic":
            return "Empfohlen: eigener API-Key (console.anthropic.com/settings/keys) — offiziell und zuverlässig. Der Claude-Abo-Login ist experimentell und für Dritt-Apps nicht garantiert."
        case "openrouter":
            return "OAuth holt automatisch einen echten API-Key (Pay-as-you-go) — oder eigenen Key einfügen. Voll unterstützt."
        case "openai":
            return "Empfohlen: eigener API-Key (platform.openai.com/api-keys) — Standard Chat Completions, zuverlässig. Der ChatGPT-Abo-Login ist experimentell und für Dritt-Apps nicht garantiert. Bild/Video brauchen ohnehin einen API-Key."
        case "xai":
            return "Empfohlen: eigener API-Key (console.x.ai) — oder Grok per OpenRouter. Der Grok-Abo-Login ist experimentell und für Dritt-Apps nicht garantiert."
        case "sub2api":
            return "Server-Adresse deiner sub2api-Instanz eintragen (nur der Host reicht, „/v1“ wird ergänzt) und den sub2api-Key als API-Key. Danach „Modelle laden“ tippen."
        default:
            if preset.editableBaseURL {
                return "Für eigene Server: Base-URL des kompatiblen Endpoints eintragen (Ollama, LM Studio, LocalAI, vLLM, LiteLLM …)."
            }
            return "Der API-Key wird nur im Geräte-Keychain gespeichert. Konten gelten für Chat, Bild und Video gemeinsam."
        }
    }
}

// PasteCodeSheet lives in Components/PasteCodeSheet.swift
