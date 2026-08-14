import SwiftUI
import UIKit

/// Quiet native design tokens: one accent, tight radius scale, restrained motion.
enum Theme {
    static let accent = Color.accentColor

    // Corner radii (chip / card / bubble)
    static let chipRadius: CGFloat = 12
    static let cardRadius: CGFloat = 16
    static let bubbleRadius: CGFloat = 22
    /// Alias kept for older call sites (tiles).
    static let tileRadius: CGFloat = 16
    /// Shared minimum for buttons, rows, and interactive controls.
    static let controlHeight: CGFloat = 44
    /// Pressed-state dip for tappable cards, tiles and chips — subtle, not toy-like.
    static let pressedScale: CGFloat = 0.96

    // Spacing (8pt grid)
    static let space1: CGFloat = 8
    static let space2: CGFloat = 12
    static let space3: CGFloat = 16
    static let space4: CGFloat = 24

    // MARK: - Motion

    enum Motion {
        /// Chips, send button, toggles.
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
        /// Empty → content, soft layout shifts.
        static let soft = Animation.spring(response: 0.4, dampingFraction: 0.9)
        /// Banners / status fade.
        static let fade = Animation.easeOut(duration: 0.2)
        /// Scroll-to-latest while streaming.
        static let scroll = Animation.easeOut(duration: 0.18)

        /// Prefer fade when Reduce Motion is on.
        static func preferSpring(_ spring: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? fade : spring
        }
    }

    // MARK: - Haptics

    /// Restrained haptic vocabulary — fire only at meaningful moments (sending,
    /// stopping, keeping an app), never on scroll or passive events.
    enum Haptics {
        /// Committing something: send a message, stop a run.
        static func send() {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }

        /// Picking something lightweight: a suggestion chip, an app tile.
        static func tap() {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        /// Something was kept / saved successfully.
        static func success() {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// Deterministic hue in [0,1) from a string (NOT String.hashValue — that is
    /// randomized per process, which would recolor tiles every launch).
    static func stableHue(_ s: String) -> Double {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360) / 360.0
    }

    /// Curated tile hues (0…1) anchored on the iOS system palette — blue,
    /// indigo, purple, pink, red, orange, warm yellow, green, mint, teal.
    /// Tiles pick from these instead of anywhere on the wheel, so identity
    /// colors always land on a tuned hue (the Shortcuts model), never on an
    /// arbitrary hash color.
    static let tileHues: [Double] = [0.58, 0.655, 0.74, 0.89, 0.99, 0.07, 0.13, 0.36, 0.47, 0.53]

    /// Deterministic curated hue for a seed: stableHue picks the palette slot.
    static func tileHue(for seed: String) -> Double {
        let slot = Int(stableHue(seed.isEmpty ? "aiity" : seed) * Double(tileHues.count)) % tileHues.count
        return tileHues[slot]
    }

    /// A stable identity fill for an app tile derived from its icon/emoji.
    /// `deep` = saturated (for white SF Symbols); otherwise pastel (for emoji).
    /// `dark` dims the same hue — identity is preserved (hue never changes
    /// with the scheme), only the light-tuned glare goes away. A single hue
    /// with a top→bottom brightness fall-off, not a hue-drift gradient.
    static func tileGradient(for seed: String, deep: Bool = false, dark: Bool = false) -> LinearGradient {
        let hue = tileHue(for: seed)
        let tone = tileTone(deep: deep, dark: dark)
        return LinearGradient(
            colors: [Color(hue: hue, saturation: tone.saturation, brightness: tone.top),
                     Color(hue: hue, saturation: tone.saturation, brightness: tone.bottom)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// HSB tone behind `tileGradient` — split out so its dark-mode invariants
    /// (dimmer, never desaturated, same hue) stay unit-testable.
    static func tileTone(deep: Bool, dark: Bool) -> (saturation: Double, top: Double, bottom: Double) {
        if dark {
            return deep ? (0.72, 0.70, 0.55) : (0.48, 0.62, 0.48)
        }
        return deep ? (0.66, 0.86, 0.66) : (0.42, 0.96, 0.86)
    }
}

// MARK: - Glass

/// Liquid-glass surface with a pre-iOS-26 fallback.
///
/// `glassEffect` only exists from iOS 26, and the deployment target is 17 — so
/// this picks the real thing where available and a material that reads
/// similarly where not, instead of gating the whole app's look on a new OS.
struct GlassSurface: ViewModifier {
    var shape: AnyShape
    /// Interactive surfaces get the reactive variant that responds to touch.
    var interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: shape
            )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
    }
}

extension View {
    /// Apply the app's glass treatment in a given shape.
    func glassSurface(
        in shape: some Shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous),
        interactive: Bool = false
    ) -> some View {
        modifier(GlassSurface(shape: AnyShape(shape), interactive: interactive))
    }
}

// MARK: - Press feedback

/// Shared pressed state for tappable cards, tiles and chips: a slight scale
/// dip on the snappy spring. Under Reduce Motion nothing moves — the label
/// only dims, which is still visible feedback.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? Theme.pressedScale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                Theme.Motion.preferSpring(Theme.Motion.snappy, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// `.buttonStyle(.pressable)` — plain look plus the shared pressed dip.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// Which appearance the user picked, independent of the system setting.
enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return "Hell"
        case .dark: return "Dunkel"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// nil = follow the device, which is what `.system` means to SwiftUI.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
