import SwiftUI
import SwiftData
import Foundation
// `AiityAppShortcuts.updateAppShortcutParameters()` — tells the system the
// mini-app / agent vocabulary changed.
import AppIntents

@main
struct AIAppApp: App {
    private let container = AIAppApp.makeContainer()

    init() {
        // First thing, before any other subsystem gets a chance to crash: this
        // rotates the previous run's record into place and installs the signal
        // and exception handlers.
        DiagnosticsRecorder.shared.install()
        // Listening from launch, not from the first local generation: the
        // warning that matters arrives while a round is already running.
        MemoryPressure.shared.start()
        // The app's ONE notification delegate, installed before anything can
        // post. Without it iOS silently swallows every notification that fires
        // while the app is foreground — the normal mini-app notify() case.
        // Installing is not a permission request; no dialog is involved.
        AppNotificationDelegate.install()
        // BGTaskScheduler requires every launch handler to be registered before
        // the app finishes launching — registering later throws. Registration
        // itself schedules nothing and asks for no permission; `scheduleAll()`
        // runs from the scene (see RootView) once there is something to keep
        // warm. See BackgroundWork.swift for what may and may not run there.
        BackgroundWorkCoordinator.shared.registerHandlers()

        #if DEBUG
        // Pull the last run's report over the console instead of asking anyone
        // to open Settings on the phone:
        //   devicectl device process launch --console \
        //     --environment-variables '{"AIITY_DUMP_DIAGNOSTICS":"1"}' com.aiity.app
        if ProcessInfo.processInfo.environment["AIITY_DUMP_DIAGNOSTICS"] != nil {
            print("=== AIITY DIAGNOSTICS BEGIN ===")
            print(DiagnosticsRecorder.shared.renderReport())
            print("=== AIITY DIAGNOSTICS END ===")
        }
        // Switch the chat provider from the command line and PERSIST it, so a
        // device left on a local model can be moved back without tapping
        // through Mehr → Anbieter. Unlike PROVIDER_SETTINGS_JSON, which only
        // overrides the current launch, this writes the setting.
        //   --environment-variables '{"AIITY_SET_PROVIDER":"anthropic"}'
        //   …or "anthropic:claude-sonnet-4-5" to pin the model too.
        if let request = ProcessInfo.processInfo.environment["AIITY_SET_PROVIDER"],
           !request.isEmpty {
            let parts = request.split(separator: ":", maxSplits: 1).map(String.init)
            var settings = ProviderSettings.load()
            settings.presetId = parts[0]
            let requested = parts.count > 1 ? parts[1] : ""
            // MLX reads `localModelId`, every other dialect reads `model`.
            // Writing `model` for MLX (as this did at first) sets a field the
            // provider never reads — the run then silently used whatever local
            // model was already selected, which made a device test look like it
            // proved something it had not.
            if settings.preset.dialect == .mlx {
                if !requested.isEmpty { settings.localModelId = requested }
            } else {
                settings.model = requested.isEmpty
                    ? ProviderPreset.preset(for: parts[0]).defaultModel
                    : requested
            }
            settings.save()
            let effective = settings.preset.dialect == .mlx ? settings.localModelId : settings.model
            print("AIITY-PROVIDER set to \(settings.presetId) model=\(effective)")
        }

        // Dump the provider-profiles blob and the active chat slot over the
        // console, so "opening a provider screen and leaving does not mutate
        // stored profiles" can be asserted from outside the app (launch, dump,
        // drive the UI, relaunch, dump again, diff):
        //   devicectl device process launch --console \
        //     --environment-variables '{"AIITY_DUMP_PROVIDERS":"1"}' com.aiity.app
        // DEBUG-gated like AIITY_DUMP_DIAGNOSTICS above — must never reach a
        // Release binary (tools/release.sh strings-checks for debug seams).
        if ProcessInfo.processInfo.environment["AIITY_DUMP_PROVIDERS"] != nil {
            print("=== AIITY PROVIDERS BEGIN ===")
            let blob = UserDefaults.standard.data(forKey: ProviderProfiles.storageKey)
            print(blob.flatMap { String(data: $0, encoding: .utf8) } ?? "(no profiles blob)")
            let settings = ProviderSettings.load()
            print("active presetId=\(settings.presetId) model=\(settings.model.isEmpty ? "(unchosen)" : settings.model)")
            print("=== AIITY PROVIDERS END ===")
        }

        MLXSelfTest.runIfRequested()
        GroupSelfTest.runIfRequested()
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
        // Timestamped: the old code deleted the PREVIOUS .corrupt copy before
        // making a new one, so a second bad launch destroyed the only surviving
        // snapshot of the user's data.
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let backup = dir.appendingPathComponent("\(name).corrupt-\(stamp)")
            try? fm.moveItem(at: url, to: backup)
        }
    }
}

struct RootView: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @ObservedObject private var sync = SyncStatus.shared
    /// Siri / Shortcuts requests waiting for a scene to carry them out.
    @ObservedObject private var intents = IntentRouter.shared
    @StateObject private var session = ChatSession()
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var accountStore = AccountStore()
    @StateObject private var onboarding = OnboardingStore()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showOnboarding = false
    @State private var selectedTab = 0
    /// Mini-app an `OpenMiniAppIntent` asked for. Presented from the root, not
    /// from the library screen, so the sandbox opens whether or not the Apps
    /// tab has ever been built.
    @State private var intentMiniApp: MiniApp?
    /// Soft floor so the launch entrance can play once instead of flashing.
    @State private var splashFinished = false

    var body: some View {
        ZStack {
            if splashFinished {
                mainInterface
                    // Opacity only. Scaling a view that owns a navigation bar
                    // makes the bar's height animate from the scaled geometry,
                    // which read as the navbar sitting too high for a moment
                    // right after launch.
                    .transition(.opacity)
            } else {
                LaunchSplashView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(
            Theme.Motion.preferSpring(Theme.Motion.soft, reduceMotion: reduceMotion),
            value: splashFinished
        )
        // Applied at the root so every sheet and pushed screen inherits it.
        .preferredColorScheme(prefs.appearance.colorScheme)
        .task {
            // Sync was just re-enabled after running local-only: records
            // created in between may never be exported on their own (whether
            // CloudKit catches up from persistent history is not guaranteed),
            // so mark every record dirty once with an invisible +1 ms bump.
            if SyncModeTransition.consumePendingCatchUp() {
                SyncModeTransition.touchAllRecords(in: modelContext)
            }
            // The store is already open by the time RootView appears, so there
            // is nothing to wait ON — this is purely the entrance finishing.
            try? await Task.sleep(nanoseconds: 950_000_000)
            splashFinished = true
        }
        // A mini-app deleted on ANOTHER device takes its record away through
        // CloudKit mirroring, which never runs the library's delete alert — so
        // both things the alert would have cleaned up are left owned by
        // nothing: the persistent cookie jar (real site logins) and the consent
        // grant (which would silently re-arm network/browser capability if a
        // record with that UUID ever returned). One pass reconciles both, in
        // that order — see the ordering note on MiniAppSessionStoreSweep before
        // adding any other caller. It waits for the initial import on its own,
        // refuses to act on a recovered or in-memory store, and does nothing at
        // all unless some grant exists, so it costs most users nothing.
        .task {
            await MiniAppSessionStoreSweep.run(context: modelContext)
        }
        .onChange(of: sync.initialImportComplete) { _, complete in
            // CloudKit cannot enforce UUID uniqueness — once the first import
            // has settled, fold any records that arrived as duplicates of
            // local ones (keep-newest only, never on a tie; see MiniAppDedup).
            if complete && sync.mode == .synced {
                MiniAppDedup.removeDuplicates(in: modelContext)
            }
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
        // Let content scroll UNDER the tab bar so its glass has something to
        // refract. With an opaque bar the effect has nothing behind it and
        // reads as a solid black pill. iOS 26 only — see GlassTabBarBackground.
        .modifier(GlassTabBarBackground())
        .environment(\.openChatTab) {
            selectedTab = 0
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            // A cover presents a separate view hierarchy — .environmentObject
            // calls positioned earlier in THIS chain (above) do not reliably
            // reach it. OnboardingModal doesn't touch settingsStore/accountStore
            // until the user taps a connect button on page 2, which is exactly
            // why this crashed there and nowhere earlier: reading either
            // property for the first time, with neither actually in the
            // cover's environment, trips EnvironmentObject's own fatal error.
            OnboardingModal(isPresented: $showOnboarding) {
                onboarding.complete()
            }
            .environmentObject(settingsStore)
            .environmentObject(accountStore)
        }
        .onChange(of: session.chatPresented) { _, presented in
            // Legacy flag from "edit in chat" / library — open Chat tab instead.
            if presented {
                selectedTab = 0
                session.chatPresented = false
            }
        }
        // Presented from the root so a Shortcut can open a mini-app without the
        // Apps tab having been visited. Same component the library uses, so
        // consent and the per-app data store behave identically.
        .sheet(item: $intentMiniApp) { app in
            MiniAppSheet(
                appId: app.id.uuidString,
                name: app.name,
                html: app.runnableHTML,
                libraryId: app.id,
                emoji: app.emoji,
                iconSymbol: app.iconSymbol
            )
            .environmentObject(session)
        }
        .onAppear {
            if !onboarding.completed {
                showOnboarding = true
            }
            Analytics.track("app_open")
            // A COLD launch from Siri can run the intent before this scene
            // exists, so the request is picked up here rather than only from
            // the onChange below.
            performIntentRoute()
            refreshMiniAppIndex()
            // Ask for the first occurrence of the background tasks. iOS decides
            // if and when they actually run; a pending request is replaced, not
            // duplicated, so re-submitting on every launch is free.
            BackgroundWorkCoordinator.shared.scheduleAll()
        }
        .onChange(of: intents.pending?.sequence) { _, _ in
            // Warm path: the app was already running, `perform()` just landed.
            performIntentRoute()
        }
        .onChange(of: scenePhase) { _, phase in
            // Keep agent streaming alive briefly in background + Live Activity.
            switch phase {
            case .background:
                DiagnosticsRecorder.shared.noteScenePhase(background: true)
                session.handleAppBackground()
                // Last guaranteed moment to capture apps created during this
                // session for the Siri/Shortcuts picker.
                refreshMiniAppIndex()
                // Leaving the app is the moment a background wake-up becomes
                // useful at all — re-arm both requests from here.
                BackgroundWorkCoordinator.shared.scheduleAll()
            case .active:
                DiagnosticsRecorder.shared.noteScenePhase(background: false)
                session.handleAppForeground()
                // Coming back can mean CloudKit imported apps from another
                // device while we were away. `save` no-ops when nothing
                // changed, so this costs one small fetch.
                refreshMiniAppIndex()
            default:
                break
            }
        }
    }

    // MARK: - Siri / Shortcuts

    /// Carry out whatever an App Intent asked for. Intents never touch the
    /// session themselves — see `IntentRouter` for why the hand-off exists.
    private func performIntentRoute() {
        guard let route = intents.consumeRoute() else { return }
        switch route {
        case .newChat(let prompt):
            selectedTab = 0
            openIntentThread(participants: [], staged: prompt)
        case .askAgent(let id, let question):
            selectedTab = 0
            // Re-check the roster: the agent could have been deleted or
            // switched off between picking it in Shortcuts and running it. An
            // unresolvable participant would otherwise produce a "group" nobody
            // is in, which answers as a plain chat with no explanation.
            let stillThere = AgentStore.active().contains { $0.id == id }
            openIntentThread(participants: stillThere ? [id] : [], staged: question)
        case .openMiniApp(let id):
            selectedTab = 1
            let descriptor = FetchDescriptor<MiniApp>(predicate: #Predicate { $0.id == id })
            intentMiniApp = try? modelContext.fetch(descriptor).first
        }
    }

    /// Open a fresh conversation and stage the text. Never sends — `ChatView`
    /// puts it in the composer and raises the keyboard, the user presses send.
    private func openIntentThread(participants: [UUID], staged: String) {
        // `newThread` refuses while a turn is running, and that refusal is
        // correct: it protects the live conversation. Falling back to staging
        // into whatever is open beats losing the user's words.
        if let threadId = session.newThread(participantAgentIds: participants) {
            session.open(threadId: threadId)
        }
        let trimmed = staged.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            intents.stagedComposerText = trimmed
        }
    }

    /// Refresh the name-only snapshot the entity query reads. `propertiesToFetch`
    /// keeps the bundled HTML out of it — the picker needs a name and an icon,
    /// not hundreds of KB per app.
    private func refreshMiniAppIndex() {
        var descriptor = FetchDescriptor<MiniApp>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.propertiesToFetch = [\.id, \.name, \.iconSymbol]
        descriptor.fetchLimit = MiniAppIndex.limit
        guard let apps = try? modelContext.fetch(descriptor) else { return }
        let changed = MiniAppIndex.save(
            apps.map { MiniAppIndex.Entry(id: $0.id, name: $0.name, symbol: $0.iconSymbol) }
        )
        // Only on a real change: re-indexing on every foreground is churn the
        // system charges us for.
        if changed {
            AiityAppShortcuts.updateAppShortcutParameters()
        }
    }
}

/// Hides the tab bar background only where the liquid-glass bar exists to
/// refract what scrolls under it (iOS 26+). On 17–25 there is no glass — hiding
/// the background would just strip the bar's legibility layer, so the system
/// default stays. Same availability split as GlassSurface in Theme.swift.
private struct GlassTabBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbarBackground(.hidden, for: .tabBar)
        } else {
            content
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
