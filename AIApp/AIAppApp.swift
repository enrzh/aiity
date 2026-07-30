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
    /// hide every saved mini-app).
    ///
    /// The ladder matters, and the order is deliberate: **relocating the store is
    /// the step that loses the user's apps**, so it comes last, after every
    /// non-destructive option has been tried. In particular a CloudKit failure
    /// (no iCloud account, entitlement not yet provisioned, container missing)
    /// must fall back to the same store *without* sync rather than throwing the
    /// data away — the local file is perfectly good, it just isn't syncing.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([MiniApp.self])

        // 1. Synced — unless the user turned iCloud off. `.automatic` only
        //    actually syncs when the entitlement is present and an iCloud
        //    account is signed in; otherwise it throws here and we drop to
        //    local-only. Both paths open the SAME store file, so switching the
        //    preference never moves or loses data.
        if AppPreferences.iCloudSyncPreference {
            let synced = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            if let container = try? ModelContainer(for: schema, configurations: synced) {
                SyncStatus.shared.report(.synced)
                return container
            }
        }

        // 2. Same file, no sync. Covers "signed out of iCloud", "iCloud Drive
        //    off", and a provisioning profile without the container.
        let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: local) {
            SyncStatus.shared.report(.localOnly)
            return container
        }

        // 3. Genuinely unreadable — only now is moving it aside justified.
        relocateCorruptStore()
        if let fresh = try? ModelContainer(for: schema, configurations: local) {
            SyncStatus.shared.report(.recovered)
            return fresh
        }
        let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        if let mem = try? ModelContainer(for: schema, configurations: inMemory) {
            SyncStatus.shared.report(.inMemory)
            return mem
        }
        fatalError("unrecoverable ModelContainer failure")
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
    /// Soft floor so the launch entrance can play once instead of flashing.
    @State private var splashFinished = false

    var body: some View {
        ZStack {
            if splashFinished {
                mainInterface
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                LaunchSplashView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(
            Theme.Motion.preferSpring(Theme.Motion.soft, reduceMotion: false),
            value: splashFinished
        )
        .task {
            // The store is already open by the time RootView appears, so there
            // is nothing to wait ON — this is purely the entrance finishing.
            try? await Task.sleep(nanoseconds: 950_000_000)
            splashFinished = true
        }
    }

    private var mainInterface: some View {
        TabView(selection: $selectedTab) {
            // Conversations are the tab's root; opening one pushes it.
            ChatListView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(0)

            LibraryView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(1)

            AgentsView()
                .tabItem { Label("Agenten", systemImage: "person.2") }
                .tag(2)

            // Skills lives under Mehr — keep the main rail focused.
            SettingsView()
                .tabItem { Label("Mehr", systemImage: "gearshape") }
                .tag(3)
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
