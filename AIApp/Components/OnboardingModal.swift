import SwiftUI

/// First-run wizard. Steps introduce chat, providers, skills, mini-apps.
struct OnboardingModal: View {
    @Binding var isPresented: Bool
    var onFinished: () -> Void

    @State private var page = 0
    /// Provider setup opened straight from onboarding, so a new user lands on a
    /// working model instead of being dropped into an unconfigured chat.
    @State private var setupPresetId: String?
    // Passed explicitly into the setup sheet below — ProviderConnectionView
    // requires both, and a missing environment object is a hard crash.
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var accountStore: AccountStore

    private let pages: [(icon: String, title: String, body: String)] = [
        (
            "sparkles",
            "Willkommen bei aiity",
            "Chat zuerst: stell Fragen oder lass Mini-Apps bauen. Alles läuft mit deinem eigenen API-Key oder lokalen Modell."
        ),
        (
            "cpu",
            "Modell verbinden",
            "Unter Mehr → KI-Anbieter Key oder Ollama einrichten, dann „Modelle laden“ / „Verbindung testen“. Oben im Chat siehst du den aktiven Anbieter."
        ),
        (
            "square.grid.2x2",
            "Apps behalten",
            "Wenn der Agent eine Mini-App baut: Vorschau → Behalten. Sie erscheint unter Apps. Zum Bearbeiten: langes Drücken → Im Chat bearbeiten."
        ),
        (
            "cpu",
            "Jetzt verbinden",
            "Wähle unten, womit aiity arbeiten soll. Ohne Modell kann der Chat nichts beantworten — das dauert nur eine Minute."
        ),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        VStack(spacing: 16) {
                            Image(systemName: pages[index].icon)
                                .font(.system(size: 48))
                                .foregroundStyle(Color.accentColor)
                                .padding(.top, 24)
                            Text(pages[index].title)
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                            Text(pages[index].body)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            Spacer()
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                // On the last page offer the three real ways to get a working
                // model, each opening its setup screen directly.
                if page == pages.count - 1 {
                    VStack(spacing: 8) {
                        connectButton("API-Key eintragen", subtitle: "OpenAI, Anthropic, OpenRouter …",
                                      systemImage: "key.fill", presetId: "openrouter")
                        connectButton("Eigenes Gateway (sub2api)", subtitle: "Eigener Server mit deinen Abos",
                                      systemImage: "server.rack", presetId: "sub2api")
                        connectButton("Lokal (Ollama / On-Device)", subtitle: "Kostenlos, ohne Cloud",
                                      systemImage: "desktopcomputer", presetId: "ollama")
                    }
                    .padding(.horizontal)
                }

                Button {
                    if page < pages.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        finish()
                    }
                } label: {
                    Text(page < pages.count - 1 ? "Weiter" : "Loslegen")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .accessibilityIdentifier("onboarding-next")

                if page < pages.count - 1 {
                    Button("Überspringen") { finish() }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 24)
            .navigationTitle("aiity")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(true)
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

    private func connectButton(
        _ title: String, subtitle: String, systemImage: String, presetId: String
    ) -> some View {
        Button {
            setupPresetId = presetId
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func finish() {
        onFinished()
        isPresented = false
    }
}

/// Identifiable wrapper so a preset id can drive a `sheet(item:)`.
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
