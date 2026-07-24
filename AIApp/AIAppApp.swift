import SwiftUI
import SwiftData

@main
struct AIAppApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: MiniApp.self)
    }
}

struct RootView: View {
    @StateObject private var session = ChatSession()
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var accountStore = AccountStore()
    @StateObject private var onboarding = OnboardingStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOnboarding = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // Chat is the main product surface — not a buried full-screen card.
            NavigationStack {
                ChatView()
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
            .tag(0)

            LibraryView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(1)

            SkillsView()
                .tabItem { Label("Skills", systemImage: "puzzlepiece.extension") }
                .tag(2)

            SettingsView()
                .tabItem { Label("Mehr", systemImage: "gearshape") }
                .tag(3)
        }
        .environmentObject(session)
        .environmentObject(settingsStore)
        .environmentObject(accountStore)
        // Refined-native look: brand accent + friendly rounded typography app-wide.
        .tint(Theme.accent)
        .fontDesign(.rounded)
        .environment(\.openChatTab) {
            selectedTab = 0
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingModal(isPresented: $showOnboarding) {
                onboarding.complete()
            }
        }
        .onChange(of: session.chatPresented) { _, presented in
            // Legacy flag from "edit in chat" / library — open Chat tab instead.
            if presented {
                selectedTab = 0
                session.chatPresented = false
            }
        }
        .onAppear {
            if !onboarding.completed {
                showOnboarding = true
            }
            Analytics.track("app_open")
        }
        .onChange(of: scenePhase) { _, phase in
            // Keep agent streaming alive briefly in background + Live Activity.
            switch phase {
            case .background:
                session.handleAppBackground()
            case .active:
                session.handleAppForeground()
            default:
                break
            }
        }
    }
}

// MARK: - Open Chat tab from deep links (library edit, etc.)

private struct OpenChatTabKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openChatTab: () -> Void {
        get { self[OpenChatTabKey.self] }
        set { self[OpenChatTabKey.self] = newValue }
    }
}
