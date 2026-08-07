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
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var accountStore: AccountStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.space4) {
                Spacer(minLength: 12)

                if page == 0 {
                    VStack(spacing: Theme.space3) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text("Dein KI-Chat.\nDeine Mini-Apps.")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                } else {
                    VStack(spacing: 10) {
                        Text("Modell verbinden")
                            .font(.title2.bold())
                        connectButton(String(localized: "API-Key"), subtitle: String(localized: "OpenAI, Anthropic, OpenRouter…"),
                                      systemImage: "key.fill") { connectRoute = .apiKeyPicker }
                        connectButton(String(localized: "Gateway"), subtitle: String(localized: "sub2api / eigener Server"),
                                      systemImage: "server.rack") { connectRoute = .preset("sub2api") }
                        connectButton(String(localized: "Lokal"), subtitle: String(localized: "Ollama / On-Device"),
                                      systemImage: "desktopcomputer") { connectRoute = .localPicker }
                    }
                    .padding(.horizontal)
                    .transition(.opacity)
                }

                Spacer()

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
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .accessibilityIdentifier("onboarding-next")

                if page == 0 {
                    Button("Überspringen") { finish() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            .sheet(item: $connectRoute) { route in
                NavigationStack {
                    switch route {
                    case .preset(let presetId):
                        ProviderConnectionView(presetId: presetId, modality: .chat)
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
                    }
                }
                .environmentObject(settingsStore)
                .environmentObject(accountStore)
            }
        }
        .interactiveDismissDisabled(true)
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
        .filter { $0.dialect != .mlx }
        .filter { !["sub2api", "ollama", "lmstudio", "localai"].contains($0.id) }
        .map(\.id)

    private func connectButton(_ title: String, subtitle: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(width: 28)
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
        .buttonStyle(.plain)
    }

    private func finish() {
        onFinished()
        isPresented = false
    }
}

private enum OnboardingConnectRoute: Identifiable {
    case preset(String)
    case apiKeyPicker
    case localPicker

    var id: String {
        switch self {
        case .preset(let id): return "preset-\(id)"
        case .apiKeyPicker: return "picker-apikey"
        case .localPicker: return "picker-local"
        }
    }
}

/// A short, scoped list of providers — not the full catalog. Reused by both
/// the "API-Key" and "Lokal" onboarding buttons, each with a different,
/// small `presetIds` set, so tapping either always ends in an actual choice
/// instead of one hard-coded preset with no way out.
private struct ProviderPickerList: View {
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
