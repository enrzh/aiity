import SwiftUI

/// First-run wizard. Steps introduce chat, providers, skills, mini-apps.
struct OnboardingModal: View {
    @Binding var isPresented: Bool
    var onFinished: () -> Void

    @State private var page = 0

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
    }

    private func finish() {
        onFinished()
        isPresented = false
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
