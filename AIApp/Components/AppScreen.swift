import SwiftUI

/// Shared page shell for secondary screens.
struct AppScreen<Content: View>: View {
    let title: String
    var scrolls = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.space3)
                }
            } else {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(Theme.space3)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Quiet grouped surface used inside custom screens.
struct AppSurface<Content: View>: View {
    var padding: CGFloat = Theme.space3
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}
