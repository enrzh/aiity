import SwiftUI

/// The aiity brand mark: a 2×2 grid of glass tiles — mini-apps assembling
/// themselves. One drawing shared by the launch splash and the onboarding
/// hero so the mark renders identically everywhere it appears.
///
/// Metrics are ratios of `tileSize` (matching the original splash values,
/// 61pt tiles / radius 9 / gap 10) so the mark scales cleanly with
/// Dynamic Type via a caller-side `@ScaledMetric`.
///
/// `progress` drives the per-tile assembly (0 = absent, 1 = landed); callers
/// own the choreography — the splash and the onboarding stagger differently.
struct AiityTileMark: View {
    var tileSize: CGFloat = 61
    var progress: [CGFloat] = [1, 1, 1, 1]

    private var gap: CGFloat { tileSize * (10.0 / 61.0) }
    private var radius: CGFloat { tileSize * (9.0 / 61.0) }

    var body: some View {
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                tile(0)
                tile(1)
            }
            HStack(spacing: gap) {
                tile(2)
                tile(3)
            }
        }
        .accessibilityHidden(true)
    }

    private func tile(_ index: Int) -> some View {
        let p = index < progress.count ? progress[index] : 1
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape
            .fill(Theme.accent.opacity(0.06 + 0.10 * Double(p)))
            .glassSurface(in: shape)
            .overlay(
                shape.strokeBorder(Theme.accent.opacity(0.45 * Double(p)), lineWidth: 1)
            )
            .frame(width: tileSize, height: tileSize)
            .scaleEffect(0.86 + 0.14 * p)
            .opacity(Double(p))
    }
}

/// Self-assembling variant: the standard entrance — tiles landing one after
/// another on the splash's spring — for surfaces that don't need to weave the
/// mark into a larger choreography. Instant under Reduce Motion.
struct AssemblingTileMark: View {
    var tileSize: CGFloat = 61
    /// Extra delay before the first tile lands (to sequence after a headline).
    var initialDelay: Double = 0.05

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Separate state per tile: animating through an array is flaky.
    @State private var tile0: CGFloat = 0
    @State private var tile1: CGFloat = 0
    @State private var tile2: CGFloat = 0
    @State private var tile3: CGFloat = 0

    var body: some View {
        AiityTileMark(tileSize: tileSize, progress: [tile0, tile1, tile2, tile3])
            .onAppear(perform: enter)
    }

    private func enter() {
        if reduceMotion {
            tile0 = 1; tile1 = 1; tile2 = 1; tile3 = 1
            return
        }
        let land = Animation.spring(response: 0.42, dampingFraction: 0.72)
        withAnimation(land.delay(initialDelay)) { tile0 = 1 }
        withAnimation(land.delay(initialDelay + 0.09)) { tile1 = 1 }
        withAnimation(land.delay(initialDelay + 0.18)) { tile2 = 1 }
        withAnimation(land.delay(initialDelay + 0.27)) { tile3 = 1 }
    }
}

#if DEBUG
#Preview("Tile mark") {
    VStack(spacing: 40) {
        AiityTileMark()
        AiityTileMark(tileSize: 34)
        AiityTileMark(tileSize: 34, progress: [1, 1, 0.5, 0])
    }
}
#endif
