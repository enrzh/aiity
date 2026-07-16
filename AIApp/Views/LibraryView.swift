import SwiftUI
import SwiftData

/// Second page: the saved mini-apps, homescreen-style.
struct LibraryView: View {
    @Query(sort: \MiniApp.updatedAt, order: .reverse) private var apps: [MiniApp]
    @Environment(\.modelContext) private var modelContext
    @State private var openApp: MiniApp?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        NavigationStack {
            Group {
                if apps.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Apps",
                        systemImage: "square.grid.2x2",
                        description: Text("Lass dir im Chat eine Mini-App bauen und tippe auf „Behalten“.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(apps) { app in
                                Button {
                                    openApp = app
                                } label: {
                                    VStack(spacing: 6) {
                                        Text(app.emoji)
                                            .font(.system(size: 40))
                                            .frame(width: 72, height: 72)
                                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                                        Text(app.name)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        modelContext.delete(app)
                                    } label: {
                                        Label("Löschen", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Meine Apps")
            .sheet(item: $openApp) { app in
                MiniAppSheet(appId: app.id.uuidString, name: app.name, html: app.html)
            }
        }
    }
}
