import SwiftUI
import SwiftData
import UIKit

struct ChatView: View {
    @EnvironmentObject private var session: ChatSession
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var accountStore: AccountStore
    @Query private var savedApps: [MiniApp]
    @State private var input = ""
    @State private var previewDraft: MiniAppDraft?
    @State private var showQuickProvider = false
    @State private var showSkills = false
    /// Non-nil while the report sheet is up, holding the message being reported.
    @State private var reportTarget: ChatMessage?
    /// Measured height of the floating input bubble — drives the scroll
    /// clearance so a multi-line input never overlaps the last message.
    @State private var inputBarHeight: CGFloat = 64
    /// Explicit keyboard top edge (screen space). The composer used to ride
    /// SwiftUI's implicit keyboard safe-area inset, which sheet dismissals
    /// with a keyboard up (worst: the MiniAppSheet WKWebView) could leave
    /// stale — parking the bar mid-screen with no keyboard visible. The view
    /// now opts out of that inset and lifts the bar itself.
    @StateObject private var keyboard = KeyboardObserver()
    /// The composer's RESTING bottom edge in global (= screen) coordinates,
    /// measured by a zero-height marker in the same bottom overlay as the bar
    /// — the lift padding never displaces the marker, so this stays the
    /// resting edge even while the bar is raised.
    @State private var composerRestingBottom: CGFloat = 0
    /// Composer focus, owned here so the keyboard can be dropped BEFORE any
    /// sheet presents — a keyboard alive through a sheet transition is what
    /// used to leave the stale inset behind.
    @FocusState private var composerFocused: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Text a Siri / Shortcuts intent wants in the composer. Staged, never
    /// sent — see `IntentRouter.stagedComposerText`.
    @ObservedObject private var intents = IntentRouter.shared

    private var visibleMessages: [ChatMessage] {
        session.messages.filter {
            // Hidden pin: full mini-app HTML for the model only.
            if ChatSession.isSourcePinMessage($0) { return false }
            switch $0.role {
            case .user: return true
            case .tool: return true
            case .assistant:
                return !ChatView.strippingHTMLFence(from: $0.text).isEmpty
                    || !$0.mediaIds.isEmpty
                    || !$0.toolCalls.isEmpty
                    || session.busy
            case .system: return false
            }
        }
    }

    static func strippingHTMLFence(from text: String) -> String {
        guard let fenceStart = text.range(of: "```html") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = String(text[..<fenceStart.lowerBound])
        if let fenceEnd = text.range(of: "```", range: fenceStart.upperBound..<text.endIndex) {
            result += text[fenceEnd.upperBound...]
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short label for the toolbar pill — model name only when possible.
    private var activeModelLabel: String {
        let s = settingsStore.settings
        if s.preset.dialect == .mlx {
            return s.localModelId.split(separator: "/").last.map(String.init) ?? "MLX"
        }
        let model = s.effectiveModel
        if model.isEmpty { return String(localized: "Modell") }
        let short = model.count > 18 ? String(model.prefix(16)) + "…" : model
        return short
    }

    private var needsSetup: Bool {
        let s = settingsStore.settings
        if s.preset.dialect == .mlx { return false }
        if ConnectionProbe.isSelfHostedEndpoint(s.presetId) {
            return s.effectiveBaseURL.isEmpty || s.effectiveModel.isEmpty
        }
        return s.effectiveModel.isEmpty
    }

    private var isEditingApp: Bool { session.editingContext != nil }

    /// How far the composer must rise above its resting position so its
    /// bottom edge sits exactly on the keyboard's top edge. 0 when hidden.
    ///
    /// Both operands live in ONE coordinate space (screen/global): the
    /// keyboard's top edge from the frame notification, the resting bottom
    /// edge from the marker overlay. Build 7 instead did height arithmetic —
    /// `keyboard.height − containerBottomInset` — which assumed the composer
    /// rests exactly at the measured container edge; on device the ancestor
    /// chrome (tab bar/home-indicator handling) broke that assumption and the
    /// bar overshot the keyboard by the difference. Subtracting positions
    /// self-corrects no matter what any ancestor already avoided, and the
    /// live marker keeps it correct even if the container itself moves.
    private var composerLift: CGFloat {
        guard let keyboardTop = keyboard.topEdge, composerRestingBottom > 0 else { return 0 }
        return max(0, composerRestingBottom - keyboardTop)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let ctx = session.editingContext {
                editingBanner(ctx)
            }


            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.space2) {
                        if needsSetup {
                            setupBanner
                        }
                        if visibleMessages.isEmpty && !session.busy {
                            emptyState
                        }
                        ForEach(visibleMessages) { message in
                            MessageBubble(
                                message: message,
                                showTyping: session.busy
                                    && message.id == visibleMessages.last?.id
                                    && message.role == .assistant
                                    && ChatView.strippingHTMLFence(from: message.text).isEmpty
                                    && message.mediaIds.isEmpty
                                    && message.toolCalls.isEmpty
                            )
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = message.text
                                } label: {
                                    Label("Kopieren", systemImage: "doc.on.doc")
                                }
                                // Guideline 1.2: what a model returns is not
                                // filtered in advance by anyone here, so there
                                // has to be a way to report it.
                                if message.role == .assistant, !message.text.isEmpty {
                                    Button(role: .destructive) {
                                        composerFocused = false
                                        reportTarget = message
                                    } label: {
                                        Label("Inhalt melden", systemImage: "flag")
                                    }
                                }
                            }
                            .id(message.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        if session.busy, let status = session.statusLine {
                            // Visible, not a11y-only: what the agent is doing
                            // right now is exactly what a waiting user wants
                            // to know. Crossfades as the phase changes.
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(status)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .contentTransition(.opacity)
                            }
                            .animation(Theme.Motion.fade, value: session.statusLine)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(session.statusLine ?? "Arbeitet")
                            .id("status-line")
                        }
                        // Another round is a deliberate tap: the agents never
                        // decide to keep talking (and spending) on their own.
                        if session.activeThreadIsGroup,
                           AppPreferences.shared.chatMode.showsContinueDiscussion,
                           !session.busy,
                           !visibleMessages.isEmpty {
                            Button {
                                session.continueGroupDiscussion(settings: settingsStore.settings)
                            } label: {
                                Label("Weiter diskutieren", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("continue-group")
                            .padding(.top, 4)
                        }
                        // A turn iOS cut short while the app was in the
                        // background. Deliberately an offer and not a silent
                        // replay: re-running costs the user's own tokens on a
                        // request that may already have completed server-side.
                        if !session.busy, session.interruptedTurn != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Antwort pausiert — die App war zu lange im Hintergrund.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    Button {
                                        session.resumeInterruptedTurn(settings: settingsStore.settings)
                                    } label: {
                                        Label("Fortsetzen", systemImage: "play.fill")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("resume-interrupted-turn")
                                    Button("Verwerfen") {
                                        session.dismissInterruptedTurn()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .id("interrupted-turn")
                        }
                        if let error = session.errorMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                BannerView(message: error, kind: .error) {
                                    session.errorMessage = nil
                                }
                                if !session.busy {
                                    Button {
                                        retryLastUserMessage()
                                    } label: {
                                        Label("Erneut", systemImage: "arrow.clockwise")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .id("error-banner")
                        }
                    }
                    .padding(.horizontal, Theme.space3)
                    .padding(.top, Theme.space2)
                    // Clearance so the last message can scroll clear of the
                    // floating input bubble (which overlays the content). Tracks
                    // the measured bubble height so a 6-line input never overlaps.
                    // composerLift keeps the clearance correct while the keyboard
                    // is up: the view no longer shrinks with the implicit keyboard
                    // inset, so the raised bar's travel must be padded explicitly.
                    .padding(.bottom, inputBarHeight + composerLift + 16)
                    .animation(
                        Theme.Motion.preferSpring(Theme.Motion.soft, reduceMotion: reduceMotion),
                        value: visibleMessages.count
                    )
                }
                // Count as well as text: a NEW message (another agent taking
                // its turn, a tool result) left the view parked where it was,
                // because only the last message's text was being watched.
                // Overlaid rather than stacked above: the transcript has to pass
                // BEHIND the card for its glass to refract anything — in a VStack
                // it sat on the window background and read as a solid block.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let draft = session.draftMiniApp {
                        MiniAppCard(
                            draft: draft,
                            isStreaming: session.busy,
                            // Drop the keyboard before the sheet slides up — a
                            // keyboard alive through the transition is the race
                            // that left the composer's inset stale.
                            onPreview: {
                                composerFocused = false
                                previewDraft = draft
                            },
                            onKeep: { keep(draft) },
                            onEditAI: {
                                session.startEditingDraft(
                                    name: draft.name,
                                    html: draft.html,
                                    emoji: draft.emoji
                                )
                            }
                        )
                        .padding(.horizontal, Theme.space3)
                        .padding(.top, Theme.space2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .onChange(of: visibleMessages.count) {
                    if let lastId = visibleMessages.last?.id {
                        withAnimation(
                            Theme.Motion.preferSpring(Theme.Motion.scroll, reduceMotion: reduceMotion)
                        ) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: visibleMessages.last?.text) {
                    if let lastId = visibleMessages.last?.id {
                        withAnimation(
                            Theme.Motion.preferSpring(Theme.Motion.scroll, reduceMotion: reduceMotion)
                        ) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: session.statusLine) {
                    if session.statusLine != nil {
                        proxy.scrollTo("status-line", anchor: .bottom)
                    }
                }

                .scrollDismissesKeyboard(.immediately)
            }
        }
        // Input floats over the scroll content so messages pass behind it.
        .overlay(alignment: .bottom) {
            inputBar
                // One queryable element for the whole bar so UI tests can
                // assert the BAR's frame against the keyboard top (chat-input
                // is the inner text pill, which sits above the bar's edge).
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat-composer-bar")
                // Soft fade so scrolled message text dissolves under the bubble
                // instead of colliding with it edge-to-edge.
                .background(alignment: .bottom) {
                    LinearGradient(
                        colors: [Color(.systemBackground).opacity(0),
                                 Color(.systemBackground).opacity(0.9)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: inputBarHeight + 28)
                    .allowsHitTesting(false)
                    .ignoresSafeArea(edges: .bottom)
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: InputBarHeightKey.self, value: geo.size.height)
                    }
                )
                // AFTER the height measurement: InputBarHeightKey keeps meaning
                // "bar height only" — the lift is added separately where needed.
                .padding(.bottom, composerLift)
        }
        // Zero-height marker pinned where the composer RESTS: same overlay
        // alignment as the bar but WITHOUT the lift padding, so its global
        // maxY is the bar's resting bottom edge at all times — shared
        // coordinate space with the keyboard notification's frame, and live
        // even when an ancestor moves this container under the keyboard.
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Color.clear.preference(
                    key: ComposerRestingBottomKey.self,
                    value: geo.frame(in: .global).maxY
                )
            }
            .frame(height: 0)
            .allowsHitTesting(false)
        }
        // Opt out of the implicit keyboard safe-area inset: it is what went
        // stale (sheet dismissed with keyboard up, AI-edit tab-switch race,
        // scene backgrounding) and parked the bar mid-screen. Position now
        // comes only from KeyboardObserver, whose didHide path always resets.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onPreferenceChange(InputBarHeightKey.self) { inputBarHeight = $0 }
        .onPreferenceChange(ComposerRestingBottomKey.self) { composerRestingBottom = $0 }
        .onDisappear { composerFocused = false }
        // A Shortcut that opened a NEW conversation pushes this view, so the
        // text is usually already waiting by the time onAppear runs; onChange
        // covers the case where this view was already on screen.
        .onAppear { stageIntentTextIfNeeded() }
        .onChange(of: intents.stagedComposerText) { _, _ in stageIntentTextIfNeeded() }
        .navigationTitle(session.activeThreadTitle.isEmpty ? "Chat" : session.activeThreadTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    session.newThread()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(session.busy)
                .accessibilityIdentifier("chat-new")
                .accessibilityLabel("Neuer Chat")

                // Plain glyphs, all three alike: a chip with its own capsule
                // background clashes with the toolbar's own grouping, and the
                // toolbar drops the chip's text when the title is long — which
                // left a bare icon on a grey square.
                Button {
                    composerFocused = false
                    showQuickProvider = true
                } label: {
                    Image(systemName: "cpu")
                }
                .accessibilityIdentifier("chat-provider")
                .accessibilityLabel(String(localized: "Modell: \(activeModelLabel)"))
                .accessibilityHint("Anbieter und Modell wählen")

                // Skills used to hide behind an overflow menu whose only other
                // entry was the provider — which already has its own button.
                Button {
                    composerFocused = false
                    showSkills = true
                } label: {
                    Image(systemName: "puzzlepiece.extension")
                }
                .accessibilityIdentifier("chat-skills")
                .accessibilityLabel("Skills")
            }
        }
        .sheet(item: $previewDraft) { draft in
            MiniAppSheet(
                appId: MiniAppConsent.previewId(html: draft.html),
                name: draft.name,
                html: draft.html,
                emoji: draft.emoji,
                iconSymbol: draft.iconSymbol
            )
            .environmentObject(session)
        }
        .sheet(isPresented: $showQuickProvider) {
            // AppSheet: every sheet shares the lifted-material chrome. The
            // focus-resign happens at the presenting button, not here.
            AppSheet(detents: [.large]) {
                NavigationStack {
                    ConnectionsView()
                }
                .environmentObject(settingsStore)
                .environmentObject(accountStore)
            }
        }
        .sheet(isPresented: $showSkills) {
            AppSheet(detents: [.large, .medium]) {
                NavigationStack {
                    SkillsView()
                }
            }
        }
        .sheet(item: $reportTarget) { message in
            ReportContentSheet(
                message: message,
                provider: settingsStore.settings.presetId,
                model: settingsStore.settings.effectiveModel,
                onDismiss: { reportTarget = nil }
            )
        }
    }

    private func editingBanner(_ ctx: ChatSession.EditingContext) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.accentColor)
            Text(ctx.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                session.editingContext = nil
                session.persistPublic()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bearbeiten beenden")
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bearbeiten: \(ctx.name)")
    }

    private var setupBanner: some View {
        BannerView(
            message: String(localized: "Noch kein Modell — oben tippen."),
            kind: .info
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Image(systemName: isEditingApp ? "wand.and.stars" : "sparkles")
                // Text style instead of a fixed size — tracks Dynamic Type.
                .font(.title.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(isEditingApp ? "Was ändern?" : "Was soll ich bauen?")
                .font(.title2.bold())
            SuggestionList(suggestions: isEditingApp ? [
                "Dunkleres Design",
                String(localized: "Bearbeiten & Löschen"),
                "Anderes Icon",
                "Netzwerk erlauben",
            ] : buildSuggestions) { suggestion in
                input = suggestion
                send()
            }
        }
        .padding(.top, Theme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only the empty state asks for model-generated ideas, so no request
        // can ever fire from a conversation that already has messages. The id
        // re-runs it when the user picks a different provider or model.
        .task(id: settingsStore.settings.presetId + "|" + settingsStore.settings.model) {
            guard !isEditingApp else { return }
            await session.refreshSmartSuggestions(
                settings: settingsStore.settings,
                savedAppCount: savedApps.count
            )
        }
    }

    /// Build-mode chips. The session owns the composition; the fallback only
    /// covers a cold path where no thread was ever activated.
    private var buildSuggestions: [String] {
        let composed = session.emptyStateSuggestions
        return composed.isEmpty
            ? Array(ChatSuggestions.buildPool.prefix(ChatSuggestions.slotCount))
            : composed
    }

    // Floating input: a text-field bubble and a round send/stop bubble — no bar.
    private var inputBar: some View {
        ChatComposer(
            text: $input,
            focus: $composerFocused,
            placeholder: isEditingApp ? String(localized: "Änderung beschreiben…") : String(localized: "Nachricht"),
            isBusy: session.busy,
            canSend: !sanitizedInput.isEmpty,
            onSend: send,
            onStop: {
                Theme.Haptics.send()
                session.stop()
            }
        ) { newValue in
            if PlainPasteboard.looksLikePasteboardArtifact(newValue) {
                input = PlainPasteboard.plainText() ?? ""
            }
        }
    }

    private var sanitizedInput: String {
        PlainPasteboard.sanitize(input) ?? ""
    }

    /// Put an intent's text in the composer and show it off — keyboard up,
    /// send button lit. It is NOT sent: a Shortcut must never be able to spend
    /// provider tokens (or pull a local model into memory) unattended. Same
    /// decision as dictation, and the reason `IntentRouter` has no "send" route
    /// at all rather than an unused flag someone could flip later.
    ///
    /// An existing draft wins: replacing something the user typed with text
    /// from an automation would destroy work.
    private func stageIntentTextIfNeeded() {
        guard sanitizedInput.isEmpty, let text = intents.takeStagedText() else { return }
        input = text
        composerFocused = true
    }

    private func send() {
        let text = sanitizedInput
        guard !text.isEmpty else {
            if PlainPasteboard.looksLikePasteboardArtifact(input) {
                session.errorMessage = String(localized: "Zwischenablage war RTF/RTFD (kein Klartext). Nochmal als Text kopieren.")
                input = ""
            }
            return
        }
        Theme.Haptics.send()
        session.send(text, settings: settingsStore.settings)
        input = ""
        Analytics.track("chat_send")
    }

    private func retryLastUserMessage() {
        guard let last = session.messages.last(where: { $0.role == .user }) else { return }
        session.errorMessage = nil
        session.send(last.text, settings: settingsStore.settings)
        Analytics.track("chat_retry")
    }

    private func keep(_ draft: MiniAppDraft) {
        if let context = session.editingContext {
            let targetId: UUID = context.id
            let descriptor = FetchDescriptor<MiniApp>(predicate: #Predicate { $0.id == targetId })
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.html = draft.html
                existing.name = draft.name
                existing.emoji = draft.emoji
                existing.iconSymbol = draft.iconSymbol
                existing.filesJSON = draft.filesJSON
                existing.version += 1
                existing.updatedAt = .now
                // Keep the pinned model context in sync for further edits.
                session.updateEditingSource(html: draft.html, name: draft.name)
                session.draftMiniApp = nil
                Analytics.track("miniapp_updated")
                return
            }
        }
        modelContext.insert(MiniApp(
            name: draft.name,
            emoji: draft.emoji,
            html: draft.html,
            filesJSON: draft.filesJSON,
            iconSymbol: draft.iconSymbol
        ))
        session.draftMiniApp = nil
        Analytics.track("miniapp_saved")
    }
}

extension MiniAppDraft: Identifiable {
    var id: String { name + String(html.hashValue) }
}

/// Reports the floating input bubble's measured height up to ChatView so the
/// scroll clearance and fade scrim can track a growing multi-line field.
private struct InputBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 64
    // max, not last-wins: ChatView has TWO bottom overlays (the bar and the
    // resting marker), and every view contributes its DEFAULT for keys it does
    // not set. With `value = nextValue()` the marker overlay, applied second,
    // overwrote the bar's measured height with the 64 pt default — the scroll
    // clearance stopped tracking a grown multi-line composer. max() is
    // order-independent, and 64 is the bar's minimum height anyway.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The composer's resting bottom edge in global coordinates — reported by the
/// zero-height bottom-overlay marker in ChatView (never displaced by the lift).
private struct ComposerRestingBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    // max for the same reason as InputBarHeightKey: a sibling overlay's
    // default (0) must not be able to overwrite the measured edge — a 0 here
    // disables the lift entirely (composerLift guards on > 0).
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Tracks the keyboard's on-screen top edge explicitly so the composer's
/// position never depends on SwiftUI's implicit keyboard safe-area inset.
///
/// That implicit inset could be left stale when a sheet was dismissed while
/// its keyboard was up (worst: MiniAppSheet's WKWebView inputs), when AI-edit
/// dismissed + switched tabs 0.35 s later, or when the scene backgrounded mid-
/// keyboard — parking the bar at former-keyboard-top height with no keyboard
/// on screen. Listening to `keyboardDidHideNotification` makes that state
/// impossible by construction: didHide fires even when a dismissal transition
/// swallows the willHide geometry, so the offset always self-heals to 0.
private final class KeyboardObserver: ObservableObject {
    /// The keyboard's top edge (endFrame.minY) in screen coordinates while it
    /// occupies screen space; nil when hidden. A POSITION, not a height: the
    /// lift is derived by subtracting this from the composer's measured
    /// resting edge in the same coordinate space, never by height arithmetic
    /// against assumed insets (the build-7 overshoot).
    @Published private(set) var topEdge: CGFloat?

    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // willChangeFrame (not willShow/willHide): it also covers height
        // changes while visible — emoji keyboard, QuickType bar, dictation —
        // and repeated frames during interactive dismissal are just re-applied.
        tokens.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.apply(note)
        })
        // The self-heal path — must also work with no preceding willChange.
        tokens.append(center.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.set(nil, duration: 0.2)
        })
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    private func apply(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        // Since iOS 16.1 the notification's object is the keyboard's UIScreen.
        let bounds = (note.object as? UIScreen)?.bounds ?? UIScreen.main.bounds
        // A hidden keyboard's end frame sits at/below the screen edge → nil.
        set(end.minY < bounds.maxY - 1 ? end.minY : nil, duration: duration)
    }

    private func set(_ newEdge: CGFloat?, duration: Double) {
        guard newEdge != topEdge else { return }
        if duration > 0 {
            // UIKit's keyboard animation is (privately) this exact spring —
            // matching it keeps the hand-driven bar glued to the keyboard edge.
            withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)) {
                topEdge = newEdge
            }
        } else {
            topEdge = newEdge
        }
    }
}


// MARK: - Bubbles

private struct MessageBubble: View {
    let message: ChatMessage
    var showTyping: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var bubbleText: String {
        message.role == .assistant ? ChatView.strippingHTMLFence(from: message.text) : message.text
    }

    var body: some View {
        switch message.role {
        case .tool:
            ToolChip(name: message.toolName ?? "tool", text: message.text)
        case .user, .assistant, .system:
            HStack {
                if message.role == .user { Spacer(minLength: 48) }
                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                    // In a group, every bubble says who is speaking — without
                    // it a discussion is an unattributed wall of text.
                    if let author = message.authorName {
                        Text("\(message.authorEmoji ?? "🤖") \(author)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.leading, 4)
                    }
                    if !message.toolCalls.isEmpty {
                        ForEach(message.toolCalls) { call in
                            ToolChip(name: call.name, text: toolSummary(call), pending: showTyping && bubbleText.isEmpty)
                        }
                    }
                    if showTyping {
                        TypingDots()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                            .accessibilityLabel("Schreibt")
                    } else if !bubbleText.isEmpty {
                        markdownText(bubbleText)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                message.role == .user
                                    ? AnyShapeStyle(Theme.accentGradient(for: colorScheme))
                                    : AnyShapeStyle(Color(.secondarySystemBackground)),
                                in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                            )
                            .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                    }
                    ForEach(message.mediaIds, id: \.self) { mediaId in
                        GeneratedMediaView(mediaId: mediaId)
                    }
                }
                if message.role == .assistant { Spacer(minLength: 48) }
            }
        }
    }

    private func toolSummary(_ call: ToolCallData) -> String {
        let args = toolArguments(call.argumentsJSON)
        switch call.name {
        case "web_search": return args["query"] as? String ?? "Suche"
        case "fetch_url": return args["url"] as? String ?? "URL"
        case "generate_image": return args["prompt"] as? String ?? "Bild"
        default: return call.name
        }
    }

    @ViewBuilder
    private func markdownText(_ text: String) -> some View {
        // AttributedString markdown — falls back to plain Text on parse failure.
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
        } else {
            Text(text)
        }
    }
}

/// Three quiet dots with a staggered rise — the platform's "someone is
/// typing" vocabulary instead of a bare spinner. Under Reduce Motion the
/// dots hold still at a readable opacity.
private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(animating ? 1 : (reduceMotion ? 0.6 : 0.4))
                    .offset(y: animating && !reduceMotion ? -3 : 1.5)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear {
            if reduceMotion {
                animating = false
            } else {
                animating = true
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ToolChip: View {
    let name: String
    let text: String
    var pending: Bool = false

    private var icon: String {
        switch name {
        case "web_search": return "magnifyingglass"
        case "fetch_url": return "doc.text"
        case "generate_image": return "photo"
        default: return "wrench.and.screwdriver"
        }
    }

    private var label: String {
        switch name {
        case "web_search": return "Web"
        case "fetch_url": return "Seite"
        case "generate_image": return "Bild"
        default: return name
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(label)
                .font(.caption2.weight(.semibold))
            if pending {
                ProgressView().controlSize(.mini)
            } else if !text.isEmpty {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08), in: Capsule())
        .accessibilityLabel("\(label): \(text)")
    }
}

private struct GeneratedMediaView: View {
    let mediaId: String

    var body: some View {
        switch MediaStore.kind(of: mediaId) {
        case .image:
            if let data = MediaStore.imageData(for: mediaId), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .accessibilityIdentifier("generated-image")
            }
        case .videoURL:
            if let url = MediaStore.videoURL(for: mediaId) {
                Link(destination: url) {
                    Label("Video ansehen", systemImage: "play.rectangle.fill")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                }
            }
        }
    }
}

private struct MiniAppCard: View {
    let draft: MiniAppDraft
    var isStreaming: Bool = false
    let onPreview: () -> Void
    let onKeep: () -> Void
    var onEditAI: (() -> Void)? = nil

    /// Brief saved-state on the keep button, so the card acknowledges the tap
    /// before its dismissal transition removes it (it used to just vanish).
    @State private var justKept = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack(spacing: 12) {
                MiniAppIconView(emoji: draft.emoji, iconSymbol: draft.iconSymbol, size: 44)
                Text(draft.name)
                    .font(.headline)
                    .lineLimit(1)
                if isStreaming {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Vorschau", action: onPreview)
                    .buttonStyle(.bordered)
                    .disabled(isStreaming && draft.html.count < 200)
                    .accessibilityIdentifier("preview-app")
                if let onEditAI {
                    Button(action: onEditAI) {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isStreaming)
                    .accessibilityLabel("Im Chat bearbeiten")
                }
                Button(action: keepTapped) {
                    HStack(spacing: 5) {
                        if justKept {
                            Image(systemName: "checkmark")
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(justKept ? "Gespeichert" : "Behalten")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(justKept ? Color.green : Color.accentColor)
                .disabled(isStreaming)
                // Not .disabled while confirming — that would gray the green
                // saved-state out. Just stop accepting a second tap.
                .allowsHitTesting(!justKept)
                .accessibilityIdentifier("keep-app")
            }
        }
        .padding(Theme.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Glass: the card now floats over the scrolling conversation, so it
        // should read as a layer above it rather than another opaque block.
        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func keepTapped() {
        Theme.Haptics.success()
        // Reduce Motion: skip the checkmark beat, keep immediately.
        guard !reduceMotion else {
            onKeep()
            return
        }
        withAnimation(Theme.Motion.snappy) { justKept = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onKeep() }
    }
}
