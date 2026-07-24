import SwiftUI

/// Small design system for a cohesive "refined native" look: one brand accent
/// (indigo → violet, mirrored by the AccentColor asset), consistent radii, and
/// stable per-app tile gradients.
enum Theme {
    static let accent = Color.accentColor

    /// Subtle indigo→violet gradient for accent surfaces (user bubbles, hero icons).
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.42, green: 0.30, blue: 0.95),
                 Color(red: 0.61, green: 0.42, blue: 1.00)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // Corner radii
    static let cardRadius: CGFloat = 20
    static let bubbleRadius: CGFloat = 22
    static let tileRadius: CGFloat = 18

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
