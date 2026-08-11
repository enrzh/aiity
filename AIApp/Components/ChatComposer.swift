import SwiftUI
import PhotosUI

struct ChatComposer: View {
    @ObservedObject private var prefs = AppPreferences.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// On-device dictation. Owned here because the transcript's only
    /// destination is this text field — nothing is auto-sent.
    @StateObject private var dictation = DictationService()
    /// The composer's text at the moment dictation started. Every partial
    /// result is composed from THIS base, so a growing partial replaces the
    /// previous one instead of stacking copies of it.
    @State private var dictationBase = ""
    /// The exact string dictation last wrote, so a user edit made WHILE
    /// dictating is distinguishable from our own write (and hands control
    /// back to the keyboard instead of being overwritten by the next partial).
    @State private var dictationApplied: String?
    @State private var showDictationNotice = false

    @Binding var text: String
    @Binding var attachments: [ChatAttachment]
    @Binding var photoItems: [PhotosPickerItem]
    /// Owned by ChatView so it can drop the keyboard before sheets present
    /// and on disappear — see the stale-keyboard-inset fix there.
    var focus: FocusState<Bool>.Binding
    let placeholder: String
    let isBusy: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onPickFile: () -> Void
    var onTextChange: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty {
                attachmentStrip
            }
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
                .focused(focus)
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
                    // Typing during a dictation means the user took over —
                    // stop listening rather than overwrite them at the next
                    // partial result.
                    if dictation.isListening, newValue != dictationApplied {
                        dictation.stop()
                    }
                    onTextChange(newValue)
                }

            dictateButton

                attachmentPicker

                Button(action: isBusy ? onStop : onSend) {
                Image(systemName: isBusy ? "stop.fill" : "arrow.up")
                    // Text style, not a fixed size, so the glyph tracks Dynamic Type.
                    .font(.body.weight(.bold))
                    // Morph arrow ↔ stop in place instead of a hard swap.
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(buttonForeground)
                    .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                    .background(buttonBackground, in: Circle())
            }
            .disabled(!isBusy && !canSend)
            // One animation context for the symbol morph and the
            // gradient ↔ gray background change; fades under Reduce Motion.
            .animation(
                Theme.Motion.preferSpring(Theme.Motion.snappy, reduceMotion: reduceMotion),
                value: isBusy
            )
            .animation(
                Theme.Motion.preferSpring(Theme.Motion.snappy, reduceMotion: reduceMotion),
                value: canSend
            )
            .accessibilityIdentifier(isBusy ? "chat-stop" : "chat-send")
            .accessibilityLabel(isBusy ? "Stopp" : "Senden")
            }
            .padding(.horizontal, Theme.space2)
            .padding(.vertical, 10)
        }
        // Live transcript → composer. Nothing is ever sent automatically; the
        // user reviews, edits and presses send themselves.
        .onChange(of: dictation.transcript) { _, spoken in
            guard !spoken.isEmpty else { return }
            let composed = DictationText.compose(base: dictationBase, transcript: spoken)
            guard composed != text else { return }
            dictationApplied = composed
            text = composed
        }
        .onChange(of: dictation.notice) { _, notice in
            showDictationNotice = notice != nil
        }
        .onChange(of: showDictationNotice) { _, shown in
            if !shown { dictation.notice = nil }
        }
        // Never hold the microphone (or the ducked audio session) past this
        // screen or into the background.
        .onDisappear { dictation.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { dictation.cancel() }
        }
        .alert(
            dictation.notice?.title ?? "",
            isPresented: $showDictationNotice,
            presenting: dictation.notice
        ) { reason in
            if reason.offersSettingsLink {
                Button(String(localized: "Einstellungen öffnen")) {
                    DictationService.openSystemSettings()
                }
            }
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { reason in
            Text(reason.message)
        }
    }

    private var attachmentPicker: some View {
        Menu {
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: 4,
                matching: .images
            ) {
                Label("Foto", systemImage: "photo")
            }
            Button(action: onPickFile) {
                Label("Datei", systemImage: "doc")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                .glassSurface(in: Circle(), interactive: true)
        }
        .disabled(isBusy)
        .accessibilityIdentifier("chat-attachments")
        .accessibilityLabel("Anhänge")
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachment.kind == .image ? "photo" : "doc")
                            .font(.caption)
                        Text(attachment.filename)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Anhang entfernen")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
            }
            .padding(.horizontal, Theme.space2)
        }
    }

    // MARK: - Dictation

    /// Mic button. On-device only: the first tap is also the ONLY place that
    /// asks for microphone / speech permission (foreground, user-initiated).
    private var dictateButton: some View {
        Button(action: toggleDictation) {
            ZStack {
                // Recording fill, opacity-animated rather than swapped in, so
                // the button keeps one identity (and one layout) in all states.
                Circle()
                    .fill(Color.red)
                    .opacity(dictation.buttonState == .listening ? 1 : 0)
                Image(systemName: dictationSymbol)
                    .font(.body.weight(.semibold))
                    // Iterative waveform while listening — motion the user can
                    // see at a glance. Static under Reduce Motion; the red fill
                    // still carries the state on its own.
                    .symbolEffect(
                        .variableColor.iterative,
                        options: .repeating,
                        isActive: dictation.buttonState == .listening && !reduceMotion
                    )
                    .foregroundStyle(dictationForeground)
            }
            // Same metric as the mode and send buttons — one baseline for the
            // whole row (and the bar height the ChatView measurement reads).
            .frame(width: Theme.controlHeight, height: Theme.controlHeight)
            .glassSurface(in: Circle(), interactive: true)
        }
        // A permanent block (no offline model for this language, or a policy
        // restriction) leaves nothing to tap; a denial stays tappable so the
        // Settings link remains reachable.
        .disabled(isBusy || dictation.buttonState == .unavailable)
        .animation(
            Theme.Motion.preferSpring(Theme.Motion.snappy, reduceMotion: reduceMotion),
            value: dictation.buttonState
        )
        .accessibilityIdentifier("chat-dictate")
        .accessibilityLabel(
            dictation.buttonState == .listening
                ? String(localized: "Diktat beenden")
                : String(localized: "Diktieren")
        )
        .accessibilityHint(
            dictation.buttonState == .unavailable
                ? String(localized: "Offline-Diktat ist für deine Sprache nicht verfügbar.")
                : String(localized: "Diktiert Gesprochenes in das Eingabefeld. Die Erkennung läuft nur auf dem Gerät.")
        )
    }

    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        // Base is captured per start, not per keystroke: the transcript is
        // appended to whatever is already typed.
        dictationBase = text
        dictationApplied = nil
        dictation.toggle()
    }

    private var dictationSymbol: String {
        switch dictation.buttonState {
        case .idle: return "mic"
        case .listening: return "waveform"
        case .unavailable: return "mic.slash"
        }
    }

    private var dictationForeground: Color {
        switch dictation.buttonState {
        case .idle: return .secondary
        case .listening: return .white
        case .unavailable: return Color.secondary.opacity(0.5)
        }
    }

    private var buttonForeground: Color {
        isBusy || canSend ? .white : .secondary
    }

    private var buttonBackground: AnyShapeStyle {
        if isBusy {
            return AnyShapeStyle(Color.red)
        }
        if canSend {
            return AnyShapeStyle(Theme.accentGradient(for: colorScheme))
        }
        return AnyShapeStyle(Color(.tertiarySystemFill))
    }
}
