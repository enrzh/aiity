import SwiftUI

/// Soft freemium gate — no StoreKit yet; explains limit and offers dismiss.
struct UpgradeModal: View {
    let title: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ModalChrome(
            title: title,
            cancelTitle: "Später",
            confirmTitle: "Verstanden",
            onCancel: onDismiss,
            onConfirm: onDismiss
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "lock.rectangle.stack")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("In-App-Käufe kommen später — Limits sind vorerst weich und lokal.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .presentationDetents([.medium])
    }
}
