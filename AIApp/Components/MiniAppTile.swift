import SwiftUI

struct MiniAppTile: View {
    let name: String
    let emoji: String
    let iconSymbol: String?
    var capabilityLabel: String?

    /// Scales with the type size so accessibility sizes don't clip the label.
    @ScaledMetric(relativeTo: .caption) private var minTileHeight: CGFloat = 126

    var body: some View {
        VStack(spacing: Theme.space1) {
            MiniAppIconView(emoji: emoji, iconSymbol: iconSymbol, size: 72)

            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if let capabilityLabel {
                Text(capabilityLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: minTileHeight, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([name, capabilityLabel].compactMap { $0 }.joined(separator: ", "))
    }
}
