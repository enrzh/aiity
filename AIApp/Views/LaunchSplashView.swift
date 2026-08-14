import SwiftUI

/// Cold-start gate, in the same editorial register as the Lexware app's splash:
/// a tracked wordmark, a hairline that grows from the centre, a staggered motif,
/// and a quiet breathing tick instead of a loader pill.
///
/// The motif is the one difference: Lexware draws three invoice rules, aiity
/// builds a small grid of tiles — mini-apps assembling themselves, which is
/// what this app actually does.
struct LaunchSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .largeTitle) private var wordmarkSize: CGFloat = 34
    @ScaledMetric(relativeTo: .caption2) private var taglineSize: CGFloat = 11

    @State private var titleOpacity: Double = 0
    @State private var titleTracking: CGFloat = 14
    @State private var ruleScale: CGFloat = 0.001
    @State private var metaOpacity: Double = 0
    // Separate state per tile: animating through an array is flaky.
    @State private var tile0: CGFloat = 0
    @State private var tile1: CGFloat = 0
    @State private var tile2: CGFloat = 0
    @State private var tile3: CGFloat = 0
    @State private var breath: CGFloat = 0.35

    private var tileProgress: [CGFloat] { [tile0, tile1, tile2, tile3] }

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    Text("aiity")
                        .font(.system(size: wordmarkSize, weight: .semibold, design: .rounded))
                        .tracking(titleTracking)
                        .foregroundStyle(.primary)
                        .opacity(titleOpacity)
                        .accessibilityAddTraits(.isHeader)

                    // Centre-growing hairline, in the accent so the mark reads
                    // as aiity rather than a generic monochrome splash.
                    Rectangle()
                        .fill(Theme.accent.opacity(0.9))
                        .frame(width: 132, height: 1)
                        .scaleEffect(x: ruleScale, y: 1, anchor: .center)
                        .padding(.top, 18)

                    Text("AI IT YOURSELF")
                        .font(.system(size: taglineSize, weight: .medium))
                        .tracking(4.5)
                        .foregroundStyle(.secondary)
                        .opacity(metaOpacity)
                        .padding(.top, 14)
                }

                // Abstract mini-apps: the shared brand mark assembling tile
                // by tile — same drawing as onboarding and the empty states.
                AiityTileMark(tileSize: 61, progress: tileProgress)
                    .padding(.top, 40)

                Spacer(minLength: 0)

                Rectangle()
                    .fill(Color.primary.opacity(breath))
                    .frame(width: 1, height: 18)
                    .padding(.bottom, 52)
                    .opacity(metaOpacity)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("aiity wird gestartet")
        .onAppear(perform: runEntrance)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(uiColor: .systemBackground),
                Color(uiColor: .systemBackground),
                Color(uiColor: colorScheme == .dark ? .secondarySystemBackground : .systemGroupedBackground)
                    .opacity(0.55),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func runEntrance() {
        if reduceMotion {
            titleOpacity = 1
            titleTracking = 4
            ruleScale = 1
            metaOpacity = 1
            tile0 = 1; tile1 = 1; tile2 = 1; tile3 = 1
            breath = 0.5
            return
        }

        // 1 — word settles, tracking tightens.
        withAnimation(.easeOut(duration: 0.55)) {
            titleOpacity = 1
            titleTracking = 4
        }
        // 2 — rule expands from the centre.
        withAnimation(.easeInOut(duration: 0.45).delay(0.18)) {
            ruleScale = 1
        }
        // 3 — tagline.
        withAnimation(.easeOut(duration: 0.4).delay(0.32)) {
            metaOpacity = 1
        }
        // 4 — tiles land one after another, like apps being built.
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72).delay(0.38)) { tile0 = 1 }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72).delay(0.47)) { tile1 = 1 }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72).delay(0.56)) { tile2 = 1 }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72).delay(0.65)) { tile3 = 1 }
        // 5 — quiet breath while the store finishes opening.
        withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true).delay(0.8)) {
            breath = 0.85
        }
    }
}

#if DEBUG
#Preview("Launch splash") {
    LaunchSplashView()
}
#endif
