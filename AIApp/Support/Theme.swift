import SwiftUI

/// Quiet native design tokens: one accent, tight radius scale, restrained motion.
enum Theme {
    static let accent = Color.accentColor

    /// Accent gradient for **user bubbles and mini-app tiles only** — not chrome.
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.42, green: 0.30, blue: 0.95),
                 Color(red: 0.61, green: 0.42, blue: 1.00)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // Corner radii (chip / card / bubble)
    static let chipRadius: CGFloat = 12
    static let cardRadius: CGFloat = 16
    static let bubbleRadius: CGFloat = 22
    /// Alias kept for older call sites (tiles).
    static let tileRadius: CGFloat = 16
    /// Shared minimum for buttons, rows, and interactive controls.
    static let controlHeight: CGFloat = 44

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

    /// Deterministic hue in [0,1) from a string (NOT String.hashValue — that is
    /// randomized per process, which would recolor tiles every launch).
    static func stableHue(_ s: String) -> Double {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360) / 360.0
    }

    /// A pleasant, stable gradient for an app tile derived from its icon/emoji.
    /// `deep` = saturated (for white SF Symbols); otherwise pastel (for emoji).
    static func tileGradient(for seed: String, deep: Bool = false) -> LinearGradient {
        let hue = stableHue(seed.isEmpty ? "aiity" : seed)
        let sat = deep ? 0.66 : 0.42
        let bri1 = deep ? 0.86 : 0.96
        let bri2 = deep ? 0.66 : 0.86
        let hue2 = (hue + 0.06).truncatingRemainder(dividingBy: 1.0)
        return LinearGradient(
            colors: [Color(hue: hue, saturation: sat, brightness: bri1),
                     Color(hue: hue2, saturation: min(1, sat + 0.08), brightness: bri2)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
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
