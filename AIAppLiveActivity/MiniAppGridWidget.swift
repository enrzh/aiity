import SwiftUI
import WidgetKit

/// Home-Screen widget with the user's most recently used mini-apps — four on
/// `systemMedium`, eight on `systemLarge` — plus a compose button that starts a
/// fresh conversation.
///
/// Every tile is its own `Link(destination: aiity://miniapp/<uuid>)` rather
/// than one `widgetURL` for the whole widget: a launcher whose tiles all open
/// the same app would be a lie, and `widgetURL` cannot be scoped to a subview.
///
/// Data arrives through `PinnedMiniAppStore.loadRecents()` (App Group defaults,
/// newest first, capped at `maxRecents`). Timeline policy is `.never` — the
/// list only changes through the app, and `PinnedMiniAppStore.saveRecents`
/// already pokes `WidgetCenter` on every real change.
///
/// German literals here on purpose — see the note in `PinnedMiniAppWidget`.

struct MiniAppGridEntry: TimelineEntry {
    let date: Date
    let apps: [PinnedMiniApp]
}

struct MiniAppGridProvider: TimelineProvider {
    /// Gallery redaction placeholder: generic samples, never the real library.
    func placeholder(in context: Context) -> MiniAppGridEntry {
        MiniAppGridEntry(
            date: .now,
            apps: [
                PinnedMiniApp(id: UUID(), name: "Mini-App", emoji: "✨", iconSymbol: nil),
                PinnedMiniApp(id: UUID(), name: "Mini-App", emoji: "✅", iconSymbol: nil),
                PinnedMiniApp(id: UUID(), name: "Mini-App", emoji: "📚", iconSymbol: nil),
                PinnedMiniApp(id: UUID(), name: "Mini-App", emoji: "🛒", iconSymbol: nil)
            ]
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (MiniAppGridEntry) -> Void) {
        completion(MiniAppGridEntry(date: .now, apps: PinnedMiniAppStore.loadRecents()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MiniAppGridEntry>) -> Void) {
        completion(Timeline(
            entries: [MiniAppGridEntry(date: .now, apps: PinnedMiniAppStore.loadRecents())],
            policy: .never
        ))
    }
}

struct MiniAppGridWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: PinnedMiniAppStore.gridWidgetKind,
            provider: MiniAppGridProvider()
        ) { entry in
            MiniAppGridWidgetView(entry: entry)
        }
        .configurationDisplayName("Mini-Apps")
        .description("Deine zuletzt genutzten Mini-Apps — ein Tipp öffnet eine davon.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct MiniAppGridWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: MiniAppGridEntry

    /// Four across in both sizes, so a tile is the same size everywhere and the
    /// large widget is the medium one with a second row.
    private static let columns = 4

    private var dark: Bool { colorScheme == .dark }
    private var rowCount: Int { family == .systemLarge ? 2 : 1 }
    /// The widest a tile can be is (content width − 3 gaps) / 4 ≈ 68pt; the
    /// large size spends the extra height on bigger icons rather than on air.
    private var iconSize: CGFloat { family == .systemLarge ? 62 : 52 }
    private var visible: [PinnedMiniApp] {
        Array(entry.apps.prefix(Self.columns * rowCount))
    }

    var body: some View {
        Group {
            if visible.isEmpty {
                emptyContent
            } else {
                VStack(spacing: 6) {
                    header
                    // Rows split the leftover height evenly and center their
                    // tiles in it — one centered row on medium, two evenly
                    // spaced rows on large, no pile-up at one edge.
                    ForEach(0..<rowCount, id: \.self) { index in
                        row(at: index)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .aiityWidgetContainerBackground(family)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Zuletzt genutzt")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Link(destination: MiniAppDeepLink.chatURL) {
                Image(systemName: "square.and.pencil")
                    .font(.footnote.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(WidgetTile.accent(dark: dark))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.fill.quaternary))
            }
            .accessibilityLabel("Neuer Chat")
        }
    }

    private func row(at index: Int) -> some View {
        let start = index * Self.columns
        let slice = Array(visible.dropFirst(start).prefix(Self.columns))
        return HStack(alignment: .top, spacing: 8) {
            ForEach(slice, id: \.id) { app in
                tile(app)
            }
            // Keep a short last row left-aligned on the same 4-column rhythm
            // instead of letting three tiles spread across the full width.
            ForEach(0..<(Self.columns - slice.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func tile(_ app: PinnedMiniApp) -> some View {
        if let url = MiniAppDeepLink.url(for: app.id) {
            Link(destination: url) { tileLabel(app) }
        } else {
            tileLabel(app)
        }
    }

    private func tileLabel(_ app: PinnedMiniApp) -> some View {
        VStack(spacing: 4) {
            WidgetMiniAppIcon(
                emoji: app.emoji,
                iconSymbol: app.iconSymbol,
                size: iconSize,
                dark: dark
            )
            Text(app.name.isEmpty ? "Mini-App" : app.name)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Fill the whole grid cell so the tap target is the cell, not just the
        // icon and its caption.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.name.isEmpty ? "Mini-App" : app.name)
    }

    /// Nothing in the library yet: the brand mark plus the one instruction that
    /// actually gets a mini-app made. Tapping opens a fresh conversation.
    private var emptyContent: some View {
        Link(destination: MiniAppDeepLink.chatURL) {
            VStack(spacing: 10) {
                WidgetBrandMark(tileSize: family == .systemLarge ? 34 : 26, dark: dark)
                VStack(spacing: 2) {
                    Text("Noch keine Mini-Apps")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Beschreib im Chat, was du brauchst")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
    }
}

#if DEBUG
private func previewApps(_ count: Int) -> [PinnedMiniApp] {
    let samples: [(String, String, String?)] = [
        ("Einkaufsliste", "🛒", nil),
        ("Notizen", "📝", "note.text"),
        ("Vokabeln", "📚", nil),
        ("Timer", "⏱️", "timer"),
        ("Budget", "💶", nil),
        ("Rezepte", "🍲", nil),
        ("Training", "🏋️", "figure.run"),
        ("Reise", "✈️", nil)
    ]
    return samples.prefix(count).map {
        PinnedMiniApp(id: UUID(), name: $0.0, emoji: $0.1, iconSymbol: $0.2)
    }
}

#Preview("Mittel", as: .systemMedium) {
    MiniAppGridWidget()
} timeline: {
    MiniAppGridEntry(date: .now, apps: previewApps(4))
    MiniAppGridEntry(date: .now, apps: previewApps(2))
    MiniAppGridEntry(date: .now, apps: [])
}

#Preview("Groß", as: .systemLarge) {
    MiniAppGridWidget()
} timeline: {
    MiniAppGridEntry(date: .now, apps: previewApps(8))
    MiniAppGridEntry(date: .now, apps: previewApps(5))
    MiniAppGridEntry(date: .now, apps: [])
}
#endif
