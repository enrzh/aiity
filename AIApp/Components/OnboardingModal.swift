import SwiftUI

/// Minimal first-run: one welcome beat, then connect.
struct OnboardingModal: View {
    @Binding var isPresented: Bool
    var onFinished: () -> Void

    @State private var page = 0
    @State private var setupPresetId: String?
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
                                      systemImage: "key.fill", presetId: "openrouter")
                        connectButton(String(localized: "Gateway"), subtitle: String(localized: "sub2api / eigener Server"),
                                      systemImage: "server.rack", presetId: "sub2api")
                        connectButton(String(localized: "Lokal"), subtitle: String(localized: "Ollama / On-Device"),
                                      systemImage: "desktopcomputer", presetId: "ollama")
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
            .sheet(item: Binding(
                get: { setupPresetId.map(OnboardingPreset.init(id:)) },
                set: { setupPresetId = $0?.id }
            )) { preset in
                NavigationStack {
                    ProviderConnectionView(presetId: preset.id, modality: .chat)
                }
                .environmentObject(settingsStore)
                .environmentObject(accountStore)
            }
        }
        .interactiveDismissDisabled(true)
    }

    private func connectButton(_ title: String, subtitle: String, systemImage: String, presetId: String) -> some View {
        Button {
            setupPresetId = presetId
        } label: {
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

private struct OnboardingPreset: Identifiable {
    let id: String
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
