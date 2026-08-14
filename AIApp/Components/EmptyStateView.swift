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
                    AssemblingTileMark(tileSize: 28)
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
