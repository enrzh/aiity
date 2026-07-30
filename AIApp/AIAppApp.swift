import SwiftUI
import SwiftData
import Foundation

@main
struct AIAppApp: App {
    private let container = AIAppApp.makeContainer()

    init() {
        #if DEBUG
        MLXSelfTest.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }

    /// Build the SwiftData store, recovering instead of fatally crashing at launch
    /// on a corrupt or schema-incompatible store (which would brick the app and
    /// hide every saved mini-app). On failure: move the bad store files aside and
    /// retry fresh; last resort is an in-memory store so the app still opens.
    private static func makeContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: MiniApp.self)
        } catch {
            relocateCorruptStore()
            if let fresh = try? ModelContainer(for: MiniApp.self) { return fresh }
            let inMemory = ModelConfiguration(isStoredInMemoryOnly: true)
            if let mem = try? ModelContainer(for: MiniApp.self, configurations: inMemory) { return mem }
            fatalError("unrecoverable ModelContainer failure: \(error)")
        }
    }

    private static func relocateCorruptStore() {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let backup = dir.appendingPathComponent(name + ".corrupt")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: url, to: backup)
        }
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

            // Skills lives under Mehr — keep the main rail to three tabs.
            SettingsView()
                .tabItem { Label("Mehr", systemImage: "gearshape") }
                .tag(2)
        }
        .environmentObject(session)
        .environmentObject(settingsStore)
        .environmentObject(accountStore)
        .tint(Theme.accent)
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
