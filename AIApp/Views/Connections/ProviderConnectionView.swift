import SwiftUI
import UIKit

/// Manages one provider for a given modality: accounts (shared), and the model
/// for that modality only. No nested image fields on chat.
struct ProviderConnectionView: View {
    let presetId: String
    var modality: ModelModality = .chat
    /// When true (default), leaving via back navigation with an active chat
    /// provider that has no chosen model first asks the user to pick one.
    /// The onboarding connect sheet passes false — OnboardingModal owns that
    /// prompt on its sheet-dismiss/finish paths, and doubling it up would ask
    /// the same question twice in a row.
    var promptsOnExit: Bool = true

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var accountStore: AccountStore
    @StateObject private var oauth = OAuthService()
    // Shared, not a fresh instance: this view is reached via NavigationLink,
    // which deallocates it on pop — a per-view store meant a download kept
    // running invisibly after the user navigated away, while navigating back
    // in showed a fresh, empty "not downloaded" state that invited a second,
    // concurrent download of the same files. See LocalModelStore's doc comment.
    @ObservedObject private var modelStore = LocalModelStore.shared

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
    /// For chat this may hold an UNCOMMITTED suggestion (a highlighted
    /// recommendation in the picker) — only the Picker/TextField bindings
    /// commit it.
    @State private var modelDraft = ""
    @State private var showLeaveWithoutModelDialog = false
    /// Per-provider tool policy, mirrored from `LocalRuntimePolicy` on appear.
    @State private var toolPolicy: LocalRuntimePolicy.ToolPolicy = .auto

    private var preset: ProviderPreset { ProviderPreset.preset(for: presetId) }
    private var isLocalWizard: Bool { ConnectionProbe.isSelfHostedEndpoint(presetId) }
    private var isActiveForModality: Bool {
        settingsStore.isActive(presetId: presetId, for: modality)
    }
    private var isChatActive: Bool { settingsStore.settings.presetId == presetId }
    private var accounts: [Account] { accountStore.accounts(for: presetId) }
    private var activeAccount: Account? { accountStore.activeAccount(for: presetId) }
    private var availableModelIds: [String] { catalogModels.map(\.id) }

    /// Leaving this screen should first ask for a model: active chat provider,
    /// connected enough to chat, nothing committed (see
    /// `ProviderConnectionModel.needsModelChoice`). Reads the live
    /// `settingsStore.settings.model` so committing a model immediately
    /// restores the normal back button.
    private var needsModelChoice: Bool {
        ProviderConnectionModel.needsModelChoice(
            preset: preset,
            modality: modality,
            isChatActive: isChatActive,
            committedModel: settingsStore.settings.model,
            accountCount: accounts.count
        )
    }

    private var interceptsExit: Bool { promptsOnExit && needsModelChoice }

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
                    toolPolicySection
                    if isActiveForModality { testConnectionSection }
                } else {
                    Section {
                        Text("On-Device MLX unterstützt nur Chat, keine Bildgenerierung.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // Show the address field during setup too — editing persists to
                // the provider profile, so activation is not a prerequisite for
                // typing the gateway address (was hidden until chat-active).
                if preset.editableBaseURL {
                    if isLocalWizard { localRuntimeWizardSection } else { baseURLSection }
                }
                if presetId == "sub2api" { sub2apiSetupSection }
                accountsSection
                if modality == .chat && isChatActive && presetId == "openai" {
                    openAIPathSection
                }
                if supportsThisModality {
                    modelSection
                    if modality == .chat { toolPolicySection }
                    if isActiveForModality || modality == .chat {
                        testConnectionSection
                    }
                }
            }
        }
        .navigationTitle(preset.label)
        .navigationBarTitleDisplayMode(.inline)
        // Exit prompt: an active chat provider without a chosen model asks on
        // the way out — pick now, or leave anyway (allowed: chat has a clear
        // "Kein Modell gewählt" error surface for that state). The system back
        // button is swapped for one that raises the question first.
        .navigationBarBackButtonHidden(interceptsExit)
        .toolbar {
            if interceptsExit {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showLeaveWithoutModelDialog = true
                    } label: {
                        Label("Zurück", systemImage: "chevron.backward")
                    }
                    .accessibilityIdentifier("provider-back")
                }
            }
        }
        .confirmationDialog(
            "Kein Modell gewählt",
            isPresented: $showLeaveWithoutModelDialog,
            titleVisibility: .visible
        ) {
            if !modelDraft.isEmpty {
                // The highlighted suggestion, one tap to make it real.
                Button(String(localized: "\(modelDraft) verwenden")) {
                    commitModel(modelDraft)
                    dismiss()
                }
            }
            Button("Ohne Modell verlassen") { dismiss() }
            Button("Modell wählen", role: .cancel) {}
        } message: {
            Text("Ohne Modell kann dieser Anbieter nicht antworten. Ein Modell lässt sich auch später unter Mehr → KI-Anbieter wählen.")
        }
        .onAppear {
            syncDraftsFromStore()
            toolPolicy = LocalRuntimePolicy.toolPolicy(forPresetId: presetId)
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
        if presetId == "anthropic" {
            return String(localized: "Nach der Autorisierung den angezeigten Code (manchmal als code#state) hier einfügen.")
        }
        return String(localized: "Autorisierungscode oder Callback-URL hier einfügen.")
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
            switch modality {
            case .chat:
                // Raw stored value, NOT effectiveModel: an empty chat model is
                // the deliberate "user has not chosen" state and must stay
                // visibly unchosen — only a real user pick fills it.
                modelDraft = settingsStore.settings.model
            case .image:
                modelDraft = settingsStore.settings.model(for: .image)
            }
        } else {
            let profile = ProviderProfiles.profile(for: presetId)
            switch modality {
            case .chat:
                // Only an actual prior choice — no preset.defaultModel
                // pre-seeding. A recommendation may still appear as an
                // uncommitted highlight via bootstrapModels().
                modelDraft = profile.model
            case .image:
                modelDraft = profile.lastImageModel.isEmpty
                    ? ModelModality.image.defaultModel : profile.lastImageModel
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
            }
        } header: {
            Text(modality.sectionTitle)
        } footer: {
            if modality == .chat {
                Text("Konten gelten für alle Nutzungsarten dieses Anbieters. Das Bild-Modell wird im Abschnitt Bild gewählt.")
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
            TextField(wizardPlaceholder, text: $hostDraft)
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
            if presetId == "sub2api" {
                Text("Adresse deiner sub2api-Instanz (Host:Port). Das iPhone muss sie erreichen — im WLAN per LAN-IP, sonst über Tailscale/VPN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Lokaler Runtime-Server")
        } footer: {
            Text("Geführtes Setup für Ollama, LM Studio, LocalAI und OpenAI-kompatible Server. Danach „Verbindung testen“.")
        }
    }

    // MARK: Tools

    /// Where a user asking "warum hat der Chat keine Websuche?" actually looks:
    /// on the provider they configured. Shows what the app decides on its own
    /// for THIS provider, and lets them override it in both directions — the
    /// small-model protection stays reachable for a tiny model behind a
    /// custom endpoint, without hiding tools from a gateway to a big one.
    private var toolPolicySection: some View {
        Section {
            Picker(selection: toolPolicyBinding) {
                ForEach(LocalRuntimePolicy.ToolPolicy.allCases) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                Label("Werkzeuge senden", systemImage: "wrench.and.screwdriver")
            }
            .accessibilityIdentifier("tool-policy-picker")

            Text(toolPolicyStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Werkzeuge")
        } footer: {
            Text("Werkzeuge sind Websuche, Seiten lesen, Bilder erzeugen und die Geräte-Tools. Kleine Modelle (Ollama, LM Studio, LocalAI, On-Device) erfinden damit oft Funktionsaufrufe statt zu antworten — nur sie bekommen deshalb standardmäßig keine. Gateways und eigene OpenAI-kompatible Server bekommen sie, weil dort meist große Modelle laufen.")
        }
    }

    private var toolPolicyBinding: Binding<LocalRuntimePolicy.ToolPolicy> {
        Binding(
            get: { toolPolicy },
            set: { newValue in
                toolPolicy = newValue
                LocalRuntimePolicy.setToolPolicy(newValue, forPresetId: presetId)
            }
        )
    }

    /// Honest, provider-specific: says what is actually happening right now,
    /// not what the setting is called.
    private var toolPolicyStatus: String {
        let dialect = preset.dialect
        guard toolPolicy == .auto else {
            return toolPolicy == .always
                ? String(localized: "Werkzeuge sind aktiv — auch bei einem kleinen Modell.")
                : String(localized: "Werkzeuge sind aus — auch bei einem großen Modell.")
        }
        if LocalRuntimePolicy.autoSendsTools(presetId: presetId, dialect: dialect) {
            return String(localized: "Automatisch heißt hier: Werkzeuge sind aktiv.")
        }
        return String(localized: "Automatisch heißt hier: keine Werkzeuge, weil hier meist kleine Modelle laufen. „Immer senden“ schaltet sie frei.")
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
            if showsOAuthButton {
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
            VStack(alignment: .leading, spacing: 4) {
                if preset.oauth?.flow == .pasteCode {
                    Text("Der Claude-Abo-Login funktioniert meist, ist aber für Dritt-Apps nicht offiziell garantiert. Für volle Zuverlässigkeit: ein eigener API-Key (Pay-as-you-go).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if presetId == "openai" || presetId == "xai" {
                    Text(String(localized: "Für \(presetId == "openai" ? "ChatGPT" : "Grok") gibt es hier keinen Abo-Login — das Abo-Token wird nur vom jeweiligen CLI-Backend akzeptiert. Nutze einen API-Key, oder dein eigenes sub2api-Gateway (Schnellstart → Gateway)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let url = apiKeyURL {
                    Link(apiKeyLinkTitle, destination: url)
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(.vertical, 2)
            if let authError {
                Text(authError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Konten")
        } footer: {
            Text(accounts.isEmpty
                 ? String(localized: "Noch kein Konto — am besten einen API-Key eintragen (Pay-as-you-go).")
                 : String(localized: "Mehrere Konten möglich; das angehakte gilt für alle Nutzungsarten dieses Anbieters."))
        }
    }

    private var oauthVerb: String {
        preset.label.components(separatedBy: " ").first ?? preset.label
    }

    /// Whether to offer the in-app sign-in button. A preset only carries an
    /// OAuth config when that sign-in actually completes and yields a usable
    /// credential (Claude subscription, OpenRouter key exchange).
    private var showsOAuthButton: Bool { preset.oauth != nil }

    /// Provider-specific sign-in verb (avoids awkward "Konto per xAI hinzufügen").
    private var oauthButtonTitle: String {
        switch presetId {
        case "anthropic": return "Mit Claude-Abo anmelden"
        case "openrouter": return "Mit OpenRouter anmelden"
        default: return String(localized: "Konto per \(oauthVerb) hinzufügen")
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
        case "openai": return String(localized: "API-Key erstellen (platform.openai.com)")
        case "anthropic": return String(localized: "API-Key erstellen (console.anthropic.com)")
        case "xai": return String(localized: "API-Key erstellen (console.x.ai)")
        default: return String(localized: "API-Key erstellen")
        }
    }

    // MARK: sub2api gateway

    /// Placeholder for the self-hosted-server address field, per preset.
    private var wizardPlaceholder: String {
        switch presetId {
        case "ollama": return "Host (z. B. http://192.168.1.10:11434)"
        case "sub2api": return "Gateway-Adresse (z. B. 192.168.1.10:8090)"
        default:
            return preset.defaultBaseURL.isEmpty
                ? "http://IP:Port oder http://Mac.local:1234"
                : "Base-URL (Standard: \(preset.defaultBaseURL))"
        }
    }

    /// The user's own sub2api web admin, served at the gateway root (the `/v1`
    /// API suffix stripped). Opens in Safari — where the user manages their
    /// provider accounts. aiity itself stays a plain sk-… client and never
    /// touches those accounts.
    private var sub2apiAdminURL: URL? {
        let raw = hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.isEmpty
            ? connectionSettings.effectiveBaseURL
            : ProviderSettings.normalizeBaseURL(raw, dialect: .openai)
        guard !normalized.isEmpty else { return nil }
        let root = normalized.hasSuffix("/v1") ? String(normalized.dropLast(3)) : normalized
        return URL(string: root)
    }

    private var sub2apiSetupSection: some View {
        Section {
            Label {
                Text("sub2api läuft auf deinem Server und hält deine Anbieter-Konten (ChatGPT/Claude/Grok). aiity verbindet sich nur als Client mit einem sk-…-Key — die Abo-Konten selbst verwaltest du in sub2api.")
                    .font(.footnote)
            } icon: {
                Image(systemName: "server.rack").foregroundStyle(Color.accentColor)
            }
            if let adminURL = sub2apiAdminURL {
                Link(destination: adminURL) {
                    Label("Konten in sub2api verwalten", systemImage: "safari")
                }
                .accessibilityIdentifier("sub2api-admin-link")
            }
            Text("Einrichten: 1. Gateway-Adresse oben eintragen. 2. sk-…-Key als Konto hinzufügen. 3. „Modelle laden“.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("sub2api-Gateway")
        }
    }

    // MARK: OpenAI path

    private var openAIPathSection: some View {
        Section {
            Label {
                Text("API-Key — Standard Chat Completions (api.openai.com). Nach „Modelle laden“ ein verfügbares Modell wählen.")
                    .font(.footnote)
            } icon: {
                Image(systemName: "key.fill")
                    .foregroundStyle(Color.accentColor)
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
            return preset.defaultModel.isEmpty ? "Modell-ID" : String(localized: "Modell (Standard: \(preset.defaultModel))")
        case .image:
            return String(localized: "Bild-Modell (z. B. gpt-image-1)")
        }
    }

    /// Prefer generative ids for the image picker when the catalog is rich.
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
        }
    }

    private var modelFooter: String {
        switch modality {
        case .chat:
            if isLocalWizard {
                return String(localized: "Liste erscheint sofort aus Cache; „Aktualisieren“ holt frische Modelle vom Server.")
            }
            return String(localized: "Modelle sind vorab geladen (Cache/Standard). „Aktualisieren“ holt die Live-Liste vom Anbieter.")
        case .image:
            return String(localized: "Nur das Bild-Modell für generate_image. Unabhängig vom Chat-Modell.")
        }
    }

    /// Show cached/default models immediately; refresh from network without blocking UI.
    private func bootstrapModels() {
        let seed = ModelCatalogCache.modelsForDisplay(presetId: presetId)
        if !seed.isEmpty {
            catalogModels = seed
            switch modality {
            case .chat:
                suggestChatModel(from: seed, settings: connectionSettings)
            case .image:
                // Image keeps its established auto-pick + commit (its own
                // modality slot; deliberately outside the choose-on-exit
                // semantics of the chat model).
                if modelDraft.isEmpty || !seed.map(\.id).contains(modelDraft) {
                    if let pick = ModelCatalogService.autoPickModel(
                        from: seed,
                        settings: connectionSettings
                    ) {
                        modelDraft = pick
                        if isActiveForModality || isChatActive {
                            commitModel(pick)
                        }
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
                    switch modality {
                    case .chat:
                        suggestChatModel(from: models, settings: snapshot)
                    case .image:
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
    }

    /// UI suggestion only — highlight a recommended CHAT model in the picker
    /// when nothing is chosen yet. Never persists anything: `commitModel` runs
    /// solely from the Picker/TextField bindings (genuine user actions) so a
    /// catalog load can never silently decide the model for the user.
    private func suggestChatModel(from models: [CatalogModel], settings: ProviderSettings) {
        guard modality == .chat, modelDraft.isEmpty,
              let pick = ModelCatalogService.autoPickModel(from: models, settings: settings) else {
            return
        }
        modelDraft = pick
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
                    bootstrapModels()
                }
            } catch {
                authError = NetworkErrorFriendly.message(for: error)
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
                        // Loading models neither commits a model nor activates
                        // the provider — the recommendation is a highlight in
                        // the picker until the user actually taps it.
                        suggestChatModel(from: pickPool, settings: snapshot)
                    } else {
                        // Image keeps its established behavior: first usable
                        // model is committed and the slot is activated.
                        if modelDraft.isEmpty || !pickPool.map(\.id).contains(modelDraft),
                           let first = pickPool.first {
                            modelDraft = first.id
                            commitModel(first.id)
                        }
                        if !isActiveForModality {
                            applyAsActive()
                        }
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
        // Testing the connection neither activates the provider nor commits a
        // model — ConnectionProbe auto-picks a model TRANSIENTLY for its test
        // chat; here the result only refreshes the catalog and the suggestion.
        let snapshot = probeSnapshot()
        Task {
            let key = await AuthStore.effectiveKey(for: snapshot)
            let result = await ConnectionProbe.test(settings: snapshot, apiKey: key)
            probeResult = result
            if result.ok, !result.models.isEmpty {
                if let rich = try? await ModelCatalogService.fetchModels(settings: snapshot, apiKey: key) {
                    catalogModels = rich
                    suggestChatModel(from: rich, settings: snapshot)
                } else {
                    catalogModels = result.models.map { CatalogModel(id: $0) }
                    suggestChatModel(from: catalogModels, settings: snapshot)
                }
            }
            probing = false
        }
    }

}

// PasteCodeSheet lives in Components/PasteCodeSheet.swift
