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

    var body: some View {
        TabView(selection: $session.activeTab) {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(0)
            LibraryView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
                .tag(2)
        }
        .environmentObject(session)
    }
}
