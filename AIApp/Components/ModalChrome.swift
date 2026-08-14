import SwiftUI

/// Shared chrome for modal sheets: NavigationStack + title + cancel/confirm toolbar.
struct ModalChrome<Content: View>: View {
    let title: String
    var cancelTitle: String = String(localized: "Abbrechen")
    var confirmTitle: String? = nil
    var confirmDisabled: Bool = false
    var confirmRole: ButtonRole? = nil
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
                            Button(confirmTitle, role: confirmRole, action: onConfirm)
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
            // Glass sheet: the content behind stays visible through it, which
            // is what makes a sheet read as lifted rather than as a new opaque
            // screen. Replaces the default solid system background.
            .presentationBackground(.regularMaterial)
    }
}

/// Reusable dismissible error / info banner — one visual line; full text for a11y.
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
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .imageScale(.medium)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(kind == .error ? Color.red : Color.primary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 44pt hit target without 44pt of layout: the negative padding
                // hands back the extra 8pt per side, so the banner stays one
                // visual line while the frame above still catches the touch.
                .padding(-8)
                .accessibilityLabel("Schließen")
            }
        }
        .padding(.horizontal, Theme.space2)
        .padding(.vertical, Theme.space2)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

/// Horizontal suggestion chips (minimal empty-state prompts).
struct SuggestionList: View {
    let suggestions: [String]
    let onTap: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { text in
                    Button {
                        Theme.Haptics.tap()
                        onTap(text)
                    } label: {
                        Text(text)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("suggestion-chip")
                }
            }
        }
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
            confirmRole: isDestructive ? .destructive : nil,
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
