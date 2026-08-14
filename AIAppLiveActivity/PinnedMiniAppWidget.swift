import SwiftUI
import WidgetKit

/// Home-Screen, Lock-Screen and StandBy widget for the ONE mini-app the user
/// pinned from the library's long-press menu — a tap opens it straight in the
/// sandboxed runner via `aiity://miniapp/<uuid>`.
///
/// Data arrives through `PinnedMiniAppStore` (App Group defaults) — the widget
/// process has no SwiftData container and must not grow one. Timeline policy is
/// `.never`: the pin only changes through the app, and every change already
/// pokes `WidgetCenter` (`PinnedMiniAppStore.pin/clear`,
/// `MiniAppSpotlightIndex.reconcile`).
///
/// German literals here on purpose — same rule as `AgentLiveActivityWidget`:
/// the widget extension has no string catalog (`AIApp/Localizable.xcstrings`
/// belongs to the app target), so a `String(localized:)` would resolve against
/// the extension's empty bundle. This adds to the known localization backlog.

struct PinnedMiniAppEntry: TimelineEntry {
    let date: Date
    let pinned: PinnedMiniApp?
}

struct PinnedMiniAppProvider: TimelineProvider {
    /// Gallery redaction placeholder: a generic sample, never the real pin.
    func placeholder(in context: Context) -> PinnedMiniAppEntry {
        PinnedMiniAppEntry(
            date: .now,
            pinned: PinnedMiniApp(id: UUID(), name: "Mini-App", emoji: "✨", iconSymbol: nil)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (PinnedMiniAppEntry) -> Void) {
        completion(PinnedMiniAppEntry(date: .now, pinned: PinnedMiniAppStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PinnedMiniAppEntry>) -> Void) {
        completion(Timeline(
            entries: [PinnedMiniAppEntry(date: .now, pinned: PinnedMiniAppStore.load())],
            policy: .never
        ))
    }
}

struct PinnedMiniAppWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: PinnedMiniAppStore.widgetKind,
            provider: PinnedMiniAppProvider()
        ) { entry in
            PinnedMiniAppWidgetView(entry: entry)
        }
        .configurationDisplayName("Angeheftete Mini-App")
        .description("Öffnet deine angeheftete Mini-App mit einem Tipp.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct PinnedMiniAppWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: PinnedMiniAppEntry

    var body: some View {
        Group {
            if let pinned = entry.pinned {
                content(pinned)
                    .widgetURL(MiniAppDeepLink.url(for: pinned.id))
            } else {
                // No `widgetURL`: the user lands at the app root, which is
                // where pinning happens.
                emptyContent
            }
        }
        .aiityWidgetContainerBackground(family)
    }

    @ViewBuilder
    private func content(_ pinned: PinnedMiniApp) -> some View {
        switch family {
        case .accessoryCircular:
            circularContent(pinned)
        case .accessoryRectangular:
            rectangularContent(pinned)
        case .systemMedium:
            HStack(spacing: 14) {
                WidgetMiniAppIcon(
                    emoji: pinned.emoji,
                    iconSymbol: pinned.iconSymbol,
                    size: 84,
                    dark: colorScheme == .dark
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName(pinned))
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text("Mini-App")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        default:
            VStack(spacing: 8) {
                WidgetMiniAppIcon(
                    emoji: pinned.emoji,
                    iconSymbol: pinned.iconSymbol,
                    size: 72,
                    dark: colorScheme == .dark
                )
                Text(displayName(pinned))
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Accessory (Lock Screen / StandBy)

    /// The plate comes from the container background — see
    /// `aiityWidgetContainerBackground`.
    private func circularContent(_ pinned: PinnedMiniApp) -> some View {
        AccessoryGlyph(pinned: pinned)
            .widgetAccentable()
            .accessibilityLabel(displayName(pinned))
    }

    private func rectangularContent(_ pinned: PinnedMiniApp) -> some View {
        HStack(spacing: 8) {
            AccessoryGlyph(pinned: pinned)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(pinned))
                    .font(.headline)
                    .lineLimit(1)
                    .widgetAccentable()
                Text("Mini-App")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Empty

    /// The nothing-pinned state: the brand mark and one quiet line on the
    /// Home Screen, a single readable line on the Lock Screen.
    @ViewBuilder
    private var emptyContent: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "square.grid.2x2")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .widgetAccentable()
                .accessibilityLabel("Keine App angeheftet")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("aiity")
                    .font(.headline)
                    .widgetAccentable()
                Text("Keine App angeheftet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        default:
            VStack(spacing: 10) {
                WidgetBrandMark(tileSize: 24, dark: colorScheme == .dark)
                Text("Keine App angeheftet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func displayName(_ pinned: PinnedMiniApp) -> String {
        pinned.name.isEmpty ? "Mini-App" : pinned.name
    }
}

/// The pinned app as a single monochrome-safe glyph.
///
/// The Lock Screen renders accessory widgets in `.vibrant`, which flattens an
/// emoji to an unreadable luminance blob — so the emoji is only used where the
/// mode is actually full color (StandBy), and everything else falls back to the
/// app's SF Symbol, then to its initial. No color carries meaning here.
private struct AccessoryGlyph: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let pinned: PinnedMiniApp

    var body: some View {
        if let symbol = pinned.iconSymbol, !symbol.isEmpty {
            Image(systemName: symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
        } else if renderingMode == .fullColor, !pinned.emoji.isEmpty {
            Text(pinned.emoji)
                .font(.title3)
        } else if let initial = pinned.name.first {
            Text(String(initial).uppercased())
                .font(.title3.weight(.semibold))
        } else {
            Image(systemName: "square.grid.2x2")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
        }
    }
}

#if DEBUG
private let previewPin = PinnedMiniApp(
    id: UUID(),
    name: "Einkaufsliste",
    emoji: "🛒",
    iconSymbol: nil
)

#Preview("Klein", as: .systemSmall) {
    PinnedMiniAppWidget()
} timeline: {
    PinnedMiniAppEntry(date: .now, pinned: previewPin)
    PinnedMiniAppEntry(date: .now, pinned: nil)
}

#Preview("Mittel", as: .systemMedium) {
    PinnedMiniAppWidget()
} timeline: {
    PinnedMiniAppEntry(date: .now, pinned: previewPin)
    PinnedMiniAppEntry(date: .now, pinned: nil)
}

#Preview("Rund", as: .accessoryCircular) {
    PinnedMiniAppWidget()
} timeline: {
    PinnedMiniAppEntry(date: .now, pinned: previewPin)
    PinnedMiniAppEntry(
        date: .now,
        pinned: PinnedMiniApp(id: UUID(), name: "Notizen", emoji: "📝", iconSymbol: "note.text")
    )
    PinnedMiniAppEntry(date: .now, pinned: nil)
}

#Preview("Rechteckig", as: .accessoryRectangular) {
    PinnedMiniAppWidget()
} timeline: {
    PinnedMiniAppEntry(date: .now, pinned: previewPin)
    PinnedMiniAppEntry(date: .now, pinned: nil)
}
#endif
