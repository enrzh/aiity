import SwiftUI

/// Minimal first-run: one welcome beat, then connect.
struct OnboardingModal: View {
    @Binding var isPresented: Bool
    var onFinished: () -> Void

    @State private var page = 0
    /// "API-Key" and "Lokal" each promise more than one provider in their own
    /// subtitle ("OpenAI, Anthropic, OpenRouter…", "Ollama / On-Device") but
    /// used to jump straight into ONE hard-coded preset — OpenRouter, or
    /// Ollama specifically, which is a REMOTE server and cannot show the
    /// on-device MLX picker at all (ProviderConnectionView only renders that
    /// for a preset whose dialect is .mlx). Neither screen offered a way
    /// back out to actually choose. Both buttons now open a scoped picker
    /// instead; only "Gateway" is genuinely one specific preset already.
    @State private var connectRoute: OnboardingConnectRoute?
    /// Connect-sheet closed with an active provider but no chosen model —
    /// ask (once) whether to pick one now or later.
    @State private var showModelPromptAfterSheet = false
    /// Same question at "Loslegen"/"Schließen" when it never got asked.
    @State private var showModelPromptOnFinish = false
    /// The user already answered "Später" once — don't nag again on the next
    /// leave path in the same onboarding session.
    @State private var declinedModelPrompt = false
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Scales the hero mark with the type size (one tile of the 2×2 grid).
    @ScaledMetric(relativeTo: .largeTitle) private var heroTileSize: CGFloat = 34

    // Entrance choreography — separate state per element: animating through
    // an array is flaky.
    @State private var heroTile0: CGFloat = 0
    @State private var heroTile1: CGFloat = 0
    @State private var heroTile2: CGFloat = 0
    @State private var heroTile3: CGFloat = 0
    @State private var titleShown = false
    @State private var row0 = false
    @State private var row1 = false
    @State private var row2 = false
    @State private var ctaShown = false
    @State private var fmRow = false
    @State private var connectRow0 = false
    @State private var connectRow1 = false
    @State private var connectRow2 = false

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.space4) {
                ZStack {
                    if page == 0 {
                        welcomePage.transition(pageTransition)
                    } else {
                        connectPage.transition(pageTransition)
                    }
                }
                // The CTA and spacers reflow on the same spring as the page
                // turn instead of resolving independently.
                .geometryGroup()

                Button {
                    if page == 0 {
                        withAnimation(
                            Theme.Motion.preferSpring(Theme.Motion.soft, reduceMotion: reduceMotion)
                        ) {
                            page = 1
                        }
                    } else {
                        finish()
                    }
                } label: {
                    Text(page == 0 ? "Weiter" : "Loslegen")
                        .frame(maxWidth: .infinity)
                        .contentTransition(.opacity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .animation(Theme.Motion.fade, value: page)
                .opacity(ctaShown ? 1 : 0)
                .accessibilityIdentifier("onboarding-next")

                if page == 0 {
                    Button("Überspringen") { finish() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .opacity(ctaShown ? 1 : 0)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.bottom, Theme.space4)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { finish() }
                        .accessibilityIdentifier("onboarding-skip")
                }
            }
            .sheet(item: $connectRoute, onDismiss: handleConnectSheetDismiss) { route in
                NavigationStack {
                    switch route {
                    case .preset(let presetId):
                        // promptsOnExit: false — the modal asks the no-model
                        // question itself on sheet dismiss / finish; the
                        // in-view back interception would double it up.
                        ProviderConnectionView(
                            presetId: presetId,
                            modality: .chat,
                            promptsOnExit: false
                        )
                    case .apiKeyPicker:
                        ProviderPickerList(
                            title: String(localized: "API-Key"),
                            presetIds: Self.apiKeyPresetIds
                        ) { connectRoute = .preset($0) }
                    case .localPicker:
                        ProviderPickerList(
                            title: String(localized: "Lokal"),
                            presetIds: ["mlx", "ollama"]
                        ) { connectRoute = .preset($0) }
                    case .modalityPicker(let modality):
                        ProviderPickerList(
                            title: modality.sectionTitle,
                            presetIds: ProviderPreset.catalog
                                .filter { MediaCapability.supports(modality, presetId: $0.id) }
                                .map(\.id)
                        ) { connectRoute = .modalityPreset($0, modality) }
                    case .modalityPreset(let presetId, let modality):
                        ProviderConnectionView(presetId: presetId, modality: modality, promptsOnExit: false)
                    }
                }
                .environmentObject(settingsStore)
                .environmentObject(accountStore)
            }
            .confirmationDialog(
                "Kein Modell gewählt",
                isPresented: $showModelPromptAfterSheet,
                titleVisibility: .visible
            ) {
                Button("Modell wählen") {
                    connectRoute = .preset(settingsStore.settings.presetId)
                }
                Button("Später", role: .cancel) { declinedModelPrompt = true }
            } message: {
                Text("\(settingsStore.settings.preset.label) ist verbunden, aber noch ohne Modell. Ohne Modell kann der Chat nicht antworten.")
            }
            .confirmationDialog(
                "Kein Modell gewählt",
                isPresented: $showModelPromptOnFinish,
                titleVisibility: .visible
            ) {
                Button("Modell wählen") {
                    connectRoute = .preset(settingsStore.settings.presetId)
                }
                Button("Ohne Modell loslegen") {
                    declinedModelPrompt = true
                    completeFinish()
                }
            } message: {
                Text("\(settingsStore.settings.preset.label) ist verbunden, aber noch ohne Modell. Ohne Modell kann der Chat nicht antworten.")
            }
        }
        .interactiveDismissDisabled(true)
    }

    /// Welcome beat: the brand mark assembles, then the headline and the
    /// three feature rows land one after another — the Journal-sheet cadence.
    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.space2)

            AiityTileMark(
                tileSize: heroTileSize,
                progress: [heroTile0, heroTile1, heroTile2, heroTile3]
            )

            Text("Willkommen bei aiity")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .opacity(titleShown ? 1 : 0)
                .offset(y: titleShown ? 0 : 12)
                .padding(.top, Theme.space4)
                .padding(.horizontal)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: Theme.space4) {
                featureRow(
                    shown: row0,
                    systemImage: "bubble.left.and.text.bubble.right",
                    title: "Dein KI-Chat",
                    subtitle: "Verbinde dein eigenes Modell — OpenAI, Anthropic oder lokal auf dem iPhone."
                )
                featureRow(
                    shown: row1,
                    systemImage: "square.grid.2x2",
                    title: "Mini-Apps aus Worten",
                    subtitle: "Beschreibe eine Idee und aiity baut daraus eine kleine App."
                )
                featureRow(
                    shown: row2,
                    systemImage: "lock",
                    title: "Deine Daten gehören dir",
                    subtitle: "API-Keys bleiben im Schlüsselbund. Kein Konto, kein aiity-Server."
                )
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, Theme.space4)
            .padding(.top, Theme.space4 + Theme.space2)

            Spacer(minLength: Theme.space2)
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: runWelcomeEntrance)
    }

    private var connectPage: some View {
        VStack(spacing: Theme.space2) {
            Spacer(minLength: Theme.space2)

            Text("Modell verbinden")
                .font(.title2.bold())
                .padding(.bottom, Theme.space1)

            Group {
                // Zero-setup path: Apple Intelligence on-device needs no key,
                // no account and no model choice — when it's live on this
                // device it goes first, and one tap finishes onboarding.
                if foundationAvailable {
                    connectButton(String(localized: "Sofort loslegen"),
                                  subtitle: String(localized: "Apple Intelligence auf diesem iPhone — kein Konto, kein Key."),
                                  systemImage: "apple.intelligence") { startWithFoundationModels() }
                        .opacity(fmRow ? 1 : 0)
                        .offset(y: fmRow ? 0 : 12)
                }
                connectButton(String(localized: "API-Key"), subtitle: String(localized: "OpenAI, Anthropic, OpenRouter…"),
                              systemImage: "key.fill") { connectRoute = .apiKeyPicker }
                    .opacity(connectRow0 ? 1 : 0)
                    .offset(y: connectRow0 ? 0 : 12)
                connectButton(String(localized: "Gateway"), subtitle: String(localized: "sub2api / eigener Server"),
                              systemImage: "server.rack") { connectRoute = .preset("sub2api") }
                    .opacity(connectRow1 ? 1 : 0)
                    .offset(y: connectRow1 ? 0 : 12)
                connectButton(String(localized: "Lokal"), subtitle: String(localized: "Ollama / On-Device"),
                              systemImage: "desktopcomputer") { connectRoute = .localPicker }
                    .opacity(connectRow2 ? 1 : 0)
                    .offset(y: connectRow2 ? 0 : 12)
            }

            Spacer()
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity)
        .onAppear(perform: runConnectEntrance)
    }

    private func featureRow(
        shown: Bool, systemImage: String,
        title: LocalizedStringKey, subtitle: LocalizedStringKey
    ) -> some View {
        HStack(spacing: Theme.space3) {
            Image(systemName: systemImage)
                .font(.title2.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 14)
    }

    /// Forward progress reads as a page turn, not a div swap — content slides
    /// toward the leading edge while the next beat springs in from trailing.
    private var pageTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
    }

    private func runWelcomeEntrance() {
        if reduceMotion {
            heroTile0 = 1; heroTile1 = 1; heroTile2 = 1; heroTile3 = 1
            titleShown = true; row0 = true; row1 = true; row2 = true
            ctaShown = true
            return
        }
        // Same landing spring as the launch splash, so splash → welcome reads
        // as one continuous brand moment.
        let land = Animation.spring(response: 0.42, dampingFraction: 0.72)
        withAnimation(land.delay(0.05)) { heroTile0 = 1 }
        withAnimation(land.delay(0.14)) { heroTile1 = 1 }
        withAnimation(land.delay(0.23)) { heroTile2 = 1 }
        withAnimation(land.delay(0.32)) { heroTile3 = 1 }
        withAnimation(Theme.Motion.soft.delay(0.25)) { titleShown = true }
        withAnimation(Theme.Motion.soft.delay(0.5)) { row0 = true }
        withAnimation(Theme.Motion.soft.delay(0.62)) { row1 = true }
        withAnimation(Theme.Motion.soft.delay(0.74)) { row2 = true }
        withAnimation(Theme.Motion.fade.delay(0.6)) { ctaShown = true }
    }

    private func runConnectEntrance() {
        if reduceMotion {
            fmRow = true; connectRow0 = true; connectRow1 = true; connectRow2 = true
            return
        }
        withAnimation(Theme.Motion.soft.delay(0.12)) { fmRow = true }
        withAnimation(Theme.Motion.soft.delay(0.2)) { connectRow0 = true }
        withAnimation(Theme.Motion.soft.delay(0.28)) { connectRow1 = true }
        withAnimation(Theme.Motion.soft.delay(0.36)) { connectRow2 = true }
    }

    /// `availability()` is the same check ConnectionProbe runs for this
    /// dialect — device eligibility, Apple Intelligence enabled, model ready.
    private var foundationAvailable: Bool {
        if case .available = AppleFoundationProvider.availability() { return true }
        return false
    }

    /// Mirrors what the provider screen's commit does for this preset:
    /// presetId + empty baseURL + the display model name. No probe needed —
    /// `foundationAvailable` IS the probe, and there is no exit prompt to
    /// trigger because the on-device dialect never requires a model choice.
    private func startWithFoundationModels() {
        var settings = settingsStore.settings
        settings.presetId = "apple-foundation"
        settings.baseURL = ""
        settings.model = ProviderPreset.preset(for: "apple-foundation").defaultModel
        settingsStore.settings = settings
        Theme.Haptics.success()
        completeFinish()
    }

    /// The chat slot is connected but has no chosen model — the state the
    /// exit prompts exist for. Same trigger logic as the provider screen.
    private var activeChatNeedsModel: Bool {
        ProviderConnectionModel.needsModelChoice(
            preset: settingsStore.settings.preset,
            modality: .chat,
            isChatActive: true,
            committedModel: settingsStore.settings.model,
            accountCount: accountStore.accounts(for: settingsStore.settings.presetId).count
        )
    }

    private func handleConnectSheetDismiss() {
        if activeChatNeedsModel && !declinedModelPrompt {
            showModelPromptAfterSheet = true
        }
    }

    /// Every chat preset that takes a key or an OAuth login — excluding
    /// sub2api/Ollama/LM Studio/LocalAI/MLX, which are what the Gateway and
    /// Lokal buttons are for. NOT filtered to `isVerified`: only 3 presets
    /// app-wide carry that flag, and excluding local/gateway ones from THAT
    /// left exactly one — OpenRouter — reproducing the identical "only one
    /// option" bug this exists to fix, just hidden behind a build that still
    /// compiled and even passed a test that didn't check every option this
    /// button's own subtitle promises by name (OpenAI, Anthropic, …).
    private static let apiKeyPresetIds: [String] = ProviderPreset.catalog
        .filter { ![.mlx, .foundation].contains($0.dialect) }
        .filter { !["sub2api", "ollama", "lmstudio", "localai"].contains($0.id) }
        .map(\.id)

    private func connectButton(_ title: String, subtitle: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.space2)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.pressable)
    }

    private func finish() {
        // Leaving onboarding with a connected-but-model-less chat provider
        // asks once (skipping without ever connecting stays a clean exit —
        // `activeChatNeedsModel` needs an account or a keyless preset).
        if activeChatNeedsModel && !declinedModelPrompt {
            showModelPromptOnFinish = true
            return
        }
        completeFinish()
    }

    private func completeFinish() {
        onFinished()
        isPresented = false
    }
}

enum OnboardingConnectRoute: Identifiable {
    case preset(String)
    case apiKeyPicker
    case localPicker
    case modalityPicker(ModelModality)
    case modalityPreset(String, ModelModality)

    var id: String {
        switch self {
        case .preset(let id): return "preset-\(id)"
        case .apiKeyPicker: return "picker-apikey"
        case .localPicker: return "picker-local"
        case .modalityPicker(let modality): return "picker-\(modality.rawValue)"
        case .modalityPreset(let presetId, let modality): return "preset-\(presetId)-\(modality.rawValue)"
        }
    }
}

/// A short, scoped list of providers — not the full catalog. Reused by both
/// the "API-Key" and "Lokal" onboarding buttons, each with a different,
/// small `presetIds` set, so tapping either always ends in an actual choice
/// instead of one hard-coded preset with no way out.
struct ProviderPickerList: View {
    let title: String
    let presetIds: [String]
    let onPick: (String) -> Void

    var body: some View {
        List(presetIds, id: \.self) { presetId in
            let preset = ProviderPreset.preset(for: presetId)
            Button {
                onPick(presetId)
            } label: {
                AppSettingsRow(
                    title: preset.label,
                    systemImage: preset.dialect == .mlx ? "iphone" : "key.fill"
                )
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
final class OnboardingStore: ObservableObject {
    @Published var completed: Bool {
        didSet { UserDefaults.standard.set(completed, forKey: Self.key) }
    }

    private static let key = "onboarding.completed.v1"

    init() {
        completed = UserDefaults.standard.bool(forKey: Self.key)
    }

    func complete() {
        completed = true
        Analytics.track("onboarding_completed")
    }
}
