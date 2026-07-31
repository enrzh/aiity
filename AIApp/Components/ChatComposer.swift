import SwiftUI

struct ChatComposer: View {
    @ObservedObject private var prefs = AppPreferences.shared

    @Binding var text: String
    let placeholder: String
    let isBusy: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    var onTextChange: (String) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Left of the input: how much the agent asks before acting.
            Menu {
                Picker("Modus", selection: $prefs.chatMode) {
                    ForEach(ChatMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
            } label: {
                Image(systemName: prefs.chatMode.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(prefs.chatMode == .auto ? Color.secondary : Theme.accent)
                    // Same metric as the send button so all three items in the
                    // row share one baseline — 34pt made it sit low and small
                    // against the input pill's minHeight.
                    .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                    .glassSurface(in: Circle(), interactive: true)
            }
            .accessibilityIdentifier("chat-mode")
            .accessibilityLabel("Modus: \(prefs.chatMode.title)")
            .accessibilityHint(prefs.chatMode.detail)

            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.space3)
                .frame(minHeight: Theme.controlHeight)
                .glassSurface(
                    in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                )
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
