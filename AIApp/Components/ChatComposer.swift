import SwiftUI

struct ChatComposer: View {
    @Binding var text: String
    let placeholder: String
    let isBusy: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    var onTextChange: (String) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.space3)
                .frame(minHeight: Theme.controlHeight)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
                .onSubmit(onSend)
                .disabled(isBusy)
                .accessibilityIdentifier("chat-input")
                .onChange(of: text) { _, newValue in
                    onTextChange(newValue)
                }

            Button(action: isBusy ? onStop : onSend) {
                Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(buttonForeground)
                    .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                    .background(buttonBackground, in: Circle())
            }
            .disabled(!isBusy && !canSend)
            .accessibilityIdentifier(isBusy ? "chat-stop" : "chat-send")
            .accessibilityLabel(isBusy ? "Stopp" : "Senden")
        }
        .padding(.horizontal, Theme.space2)
        .padding(.vertical, 10)
    }

    private var buttonForeground: Color {
        isBusy || canSend ? .white : .secondary
    }

    private var buttonBackground: AnyShapeStyle {
        if isBusy {
            return AnyShapeStyle(Color.red)
        }
        if canSend {
            return AnyShapeStyle(Theme.accentGradient)
        }
        return AnyShapeStyle(Color(.tertiarySystemFill))
    }
}
