import SwiftUI
import WidgetKit

/// Home-Screen widget for the ONE mini-app the user pinned from the library's
/// long-press menu — a tap opens it straight in the sandboxed runner via
/// `aiity://miniapp/<uuid>`.
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PinnedMiniAppWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: PinnedMiniAppEntry

    var body: some View {
        Group {
            if let pinned = entry.pinned {
                pinnedContent(pinned)
                    .widgetURL(MiniAppDeepLink.url(for: pinned.id))
            } else {
                emptyContent
            }
        }
        .containerBackground(for: .widget) {
            Color(uiColor: .systemBackground)
        }
    }

    @ViewBuilder
    private func pinnedContent(_ pinned: PinnedMiniApp) -> some View {
        switch family {
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

    /// The nothing-pinned state: the app mark (2×2 tile grid, one curated hue
    /// per tile) and one quiet line. Tapping it opens the app root — no
    /// `widgetURL`, so the user lands where pinning happens.
    private var emptyContent: some View {
        VStack(spacing: 10) {
            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                GridRow {
                    markTile("✨")
                    markTile("✅")
                }
                GridRow {
                    markTile("📚")
                    markTile("🛒")
                }
            }
            Text("Keine App angeheftet")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func markTile(_ seed: String) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(WidgetTile.gradient(for: seed, deep: false, dark: colorScheme == .dark))
            .frame(width: 24, height: 24)
    }

    private func displayName(_ pinned: PinnedMiniApp) -> String {
        pinned.name.isEmpty ? "Mini-App" : pinned.name
    }
}

// MARK: - Tile look (local mirror of Theme.swift)

/// The identity-color math from `Theme.tileHue`/`tileGradient`/`tileTone`,
/// duplicated because the extension target does not compile `Theme.swift`
/// (project.yml pulls only the shared service files in) and the tile on the
/// Home Screen must match the tile in the app exactly. KEEP IN LOCKSTEP with
/// `AIApp/Support/Theme.swift` — same hues, same tones, same seed hash.
private enum WidgetTile {
    /// Curated tile hues (0…1) anchored on the iOS system palette — see
    /// `Theme.tileHues`.
    static let hues: [Double] = [0.58, 0.655, 0.74, 0.89, 0.99, 0.07, 0.13, 0.36, 0.47, 0.53]

    /// djb2 over UTF-8 — NOT `String.hashValue`, which is randomized per
    /// process and would recolor the widget on every redraw.
    static func stableHue(_ s: String) -> Double {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360) / 360.0
    }

    static func hue(for seed: String) -> Double {
        let slot = Int(stableHue(seed.isEmpty ? "aiity" : seed) * Double(hues.count)) % hues.count
        return hues[slot]
    }

    static func tone(deep: Bool, dark: Bool) -> (saturation: Double, top: Double, bottom: Double) {
        if dark {
            return deep ? (0.72, 0.70, 0.55) : (0.48, 0.62, 0.48)
        }
        return deep ? (0.66, 0.86, 0.66) : (0.42, 0.96, 0.86)
    }

    static func gradient(for seed: String, deep: Bool, dark: Bool) -> LinearGradient {
        let hue = hue(for: seed)
        let tone = tone(deep: deep, dark: dark)
        return LinearGradient(
            colors: [Color(hue: hue, saturation: tone.saturation, brightness: tone.top),
                     Color(hue: hue, saturation: tone.saturation, brightness: tone.bottom)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// Local mirror of `MiniAppIconView` (app target): SF Symbol if set, else
/// emoji, on the seed-colored rounded tile with the white rim.
private struct WidgetMiniAppIcon: View {
    var emoji: String
    var iconSymbol: String?
    var size: CGFloat
    var dark: Bool

    private var isSymbol: Bool { !(iconSymbol ?? "").isEmpty }
    private var seed: String { (iconSymbol ?? "") + emoji }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(WidgetTile.gradient(for: seed, deep: isSymbol, dark: dark))
            .frame(width: size, height: size)
            .overlay {
                if let iconSymbol, isSymbol {
                    Image(systemName: iconSymbol)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(emoji.isEmpty ? "✨" : emoji)
                        .font(.system(size: size * 0.56))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            )
    }
}
