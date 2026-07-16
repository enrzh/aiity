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
    var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            LibraryView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
    }
}
