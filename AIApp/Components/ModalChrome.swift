import SwiftUI

/// Shared chrome for modal sheets: NavigationStack + title + cancel/confirm toolbar.
struct ModalChrome<Content: View>: View {
    let title: String
    var cancelTitle: String = "Abbrechen"
    var confirmTitle: String? = nil
    var confirmDisabled: Bool = false
    var onCancel: () -> Void
    var onConfirm: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cancelTitle, action: onCancel)
                    }
                    if let confirmTitle, let onConfirm {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(confirmTitle, action: onConfirm)
                                .disabled(confirmDisabled)
                                .fontWeight(.semibold)
                        }
                    }
                }
        }
    }
}

/// Sheet wrapper that presents `content` with standard detents.
struct AppSheet<Content: View>: View {
    var detents: Set<PresentationDetent> = [.medium, .large]
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
    }
}

/// Reusable dismissible error / info banner for lists and chat.
struct BannerView: View {
    enum Kind { case error, info, success }

    let message: String
    var kind: Kind = .error
    var onDismiss: (() -> Void)? = nil

    private var color: Color {
        switch kind {
        case .error: return .red
        case .info: return .secondary
        case .success: return .green
        }
    }

    private var icon: String {
        switch kind {
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(message)
                .font(.footnote)
                .foregroundStyle(kind == .error ? Color.red : Color.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Schließen")
            }
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Horizontal/vertical suggestion chips.
struct SuggestionList: View {
    let suggestions: [String]
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(suggestions, id: \.self) { text in
                Button {
                    onTap(text)
                } label: {
                    Text(text)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("suggestion-chip")
            }
        }
    }
}

/// Compact active model / provider label.
struct ActiveModelChip: View {
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.caption2)
            Text(label).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemBackground))
        .accessibilityIdentifier("active-model-chip")
    }
}

/// Confirm / cancel alert-style modal content for sheets.
struct ConfirmModal: View {
    let title: String
    let message: String
    var confirmTitle: String = "OK"
    var isDestructive: Bool = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ModalChrome(
            title: title,
            confirmTitle: confirmTitle,
            onCancel: onCancel,
            onConfirm: onConfirm
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .presentationDetents([.height(220), .medium])
    }
}
