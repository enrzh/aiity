import SwiftUI

/// Compact empty state with one instruction and an optional primary action.
/// The icon takes a single symbol bounce on appear; `showsTileMotif` adds the
/// brand's assembling-tiles mark above it (used on the Apps tab, where the
/// motif — mini-apps building themselves — is literally what is missing).
struct AppEmptyState: View {
    let title: String
    let systemImage: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var showsTileMotif: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounced = false

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: Theme.space3) {
                if showsTileMotif {
                    EmptyStateTileMotif()
                }
                Label(title, systemImage: systemImage)
                    .symbolEffect(.bounce, options: .nonRepeating, value: bounced)
            }
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // One-shot; Reduce Motion never triggers the bounce at all.
            if !reduceMotion { bounced = true }
        }
    }
}

/// The launch splash's 2×2 tile mark at empty-state scale: tiles land one
/// after another, like apps being built. Purely decorative — hidden from
/// accessibility, and instant under Reduce Motion.
private struct EmptyStateTileMotif: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Separate state per tile: animating through an array is flaky.
    @State private var tile0: CGFloat = 0
    @State private var tile1: CGFloat = 0
    @State private var tile2: CGFloat = 0
    @State private var tile3: CGFloat = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                tile(tile0)
                tile(tile1)
            }
            HStack(spacing: 6) {
                tile(tile2)
                tile(tile3)
            }
        }
        .onAppear(perform: enter)
        .accessibilityHidden(true)
    }

    private func tile(_ progress: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return shape
            .fill(Theme.accent.opacity(0.06 + 0.10 * Double(progress)))
            .overlay(
                shape.strokeBorder(Theme.accent.opacity(0.45 * Double(progress)), lineWidth: 1)
            )
            .frame(width: 28, height: 28)
            .scaleEffect(0.86 + 0.14 * progress)
            .opacity(Double(progress))
    }

    private func enter() {
        if reduceMotion {
            tile0 = 1; tile1 = 1; tile2 = 1; tile3 = 1
            return
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72).delay(0.05)) { tile0 = 1 }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72).delay(0.14)) { tile1 = 1 }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72).delay(0.23)) { tile2 = 1 }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72).delay(0.32)) { tile3 = 1 }
    }
}
