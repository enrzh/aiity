import SwiftUI
import WidgetKit

// The app's tile look, mirrored for the widget extension.
//
// The extension target does not compile `Theme.swift` or `MiniAppSheet.swift`
// (project.yml pulls in only the shared service files), and a tile on the Home
// Screen has to match the same tile inside the app exactly. So this file is the
// ONE local mirror every widget in the bundle draws from — never a second copy
// per widget. KEEP IN LOCKSTEP with `AIApp/Support/Theme.swift` (hues, tones,
// seed hash, accent) and `MiniAppIconView` in `AIApp/Components/MiniAppSheet.swift`.

/// The identity-color math from `Theme.tileHue`/`tileGradient`/`tileTone`.
enum WidgetTile {
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

    /// `Theme.accent` (= the app's `AccentColor` asset), hardcoded because the
    /// extension's asset catalog carries no accent color — `Color.accentColor`
    /// would resolve to the system blue here and the brand mark would not match
    /// the app. Values are the two appearances of
    /// `AIApp/Assets.xcassets/AccentColor.colorset`.
    static func accent(dark: Bool) -> Color {
        dark
            ? Color(.sRGB, red: 0.541, green: 0.486, blue: 1.000, opacity: 1)
            : Color(.sRGB, red: 0.357, green: 0.298, blue: 0.910, opacity: 1)
    }
}

/// Local mirror of `MiniAppIconView` (app target): SF Symbol if set, else
/// emoji, on the seed-colored rounded tile with the white rim.
struct WidgetMiniAppIcon: View {
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
                // The rim sits on the colored tile, never on the scheme
                // background — white reads correctly in both schemes.
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            )
    }
}

/// Local mirror of `AiityTileMark`: the brand mark, a 2×2 grid of accent tiles.
/// Flat fill + rim instead of the app's glass surface — a widget has no live
/// backdrop to refract, and chrome here stays gradient-free.
struct WidgetBrandMark: View {
    var tileSize: CGFloat = 24
    var dark: Bool

    private var gap: CGFloat { tileSize * (10.0 / 61.0) }
    private var radius: CGFloat { tileSize * (9.0 / 61.0) }

    var body: some View {
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                tile
                tile
            }
            HStack(spacing: gap) {
                tile
                tile
            }
        }
        .accessibilityHidden(true)
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape
            .fill(WidgetTile.accent(dark: dark).opacity(0.16))
            .overlay(shape.strokeBorder(WidgetTile.accent(dark: dark).opacity(0.45), lineWidth: 1))
            .frame(width: tileSize, height: tileSize)
    }
}

extension WidgetFamily {
    /// Lock Screen / StandBy families. They are drawn into a vibrant material
    /// the system owns, so they get no container fill and no color-carried
    /// meaning.
    var isAccessory: Bool {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: return true
        default: return false
        }
    }
}

extension View {
    /// The container background every widget in this bundle uses.
    ///
    /// The circular accessory gets its plate from here rather than from an
    /// `AccessoryWidgetBackground()` inside the content on purpose: a container
    /// background is drawn edge to edge, behind the system's content margins,
    /// so the plate fills the whole circle instead of sitting a few points
    /// inside it. Rectangular and inline get nothing — the Lock Screen already
    /// paints their material, and a fill would show as a slab on top of it.
    @ViewBuilder
    func aiityWidgetContainerBackground(_ family: WidgetFamily) -> some View {
        switch family {
        case .accessoryCircular:
            containerBackground(for: .widget) { AccessoryWidgetBackground() }
        case .accessoryRectangular, .accessoryInline:
            containerBackground(Color.clear, for: .widget)
        default:
            containerBackground(.fill.tertiary, for: .widget)
        }
    }
}
