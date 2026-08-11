import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ChatAttachmentImportState {
    struct Token: Equatable { let generation: Int }

    private(set) var generation = 0
    private(set) var pending = 0
    var isImporting: Bool { pending > 0 }

    mutating func beginBatch(count: Int = 1) -> Token {
        generation += 1
        pending = count
        return Token(generation: generation)
    }

    func accepts(_ token: Token) -> Bool {
        token.generation == generation && pending > 0
    }

    @discardableResult
    mutating func finish(_ token: Token) -> Bool {
        guard accepts(token) else { return false }
        pending -= 1
        if pending == 0 { generation += 1 }
        return true
    }

    mutating func invalidate() {
        generation += 1
        pending = 0
    }
}
import Foundation

enum ChatToolVisualState: Equatable {
    case active
    case completed
    case failed
}

struct ChatMediaPreviewRoute: Identifiable, Equatable {
    let mediaIds: [String]
    let selectedId: String

    var id: String { selectedId }
}

struct ChatView: View {
    @EnvironmentObject private var session: ChatSession
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var accountStore: AccountStore
    @Query private var savedApps: [MiniApp]
    @State private var input = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var attachmentImportState = ChatAttachmentImportState()
    @State private var mediaPreviewRoute: ChatMediaPreviewRoute?
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
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var bottomSentinelBottom: CGFloat = 0
    @State private var scrollContentTop: CGFloat = 0
    @State private var scrollContentHeight: CGFloat = 0
    @State private var isNearBottom = true
    @State private var showJumpToLatest = false
    @State private var scrollToLatestRequest = 0
#if DEBUG
    @State private var uiTestFixtureDelivered = false
#endif
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
                    || !$0.attachments.isEmpty
                    || !$0.toolCalls.isEmpty
                    || session.busy
            case .system: return false
            }
        }
    }

    static func strippingHTMLFence(from text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == "```html"
        }) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let end = lines[(start + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "```"
        }) else {
            guard start > 0 else {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return lines[..<start]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        lines.replaceSubrange(start...end, with: [""])
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isNearBottom(
        contentBottom: CGFloat,
        viewportBottom: CGFloat,
        threshold: CGFloat = 72
    ) -> Bool {
        contentBottom <= viewportBottom + threshold
    }

    static func trueContentBottom(
        contentTop: CGFloat,
        contentHeight: CGFloat,
        sentinelBottom: CGFloat
    ) -> CGFloat {
        contentHeight > 0 ? contentTop + contentHeight : sentinelBottom
    }

    static func markdownAttributedString(
        _ text: String,
        parser: ((String) throws -> AttributedString)? = nil
    ) -> AttributedString {
        let parse = parser ?? { try AttributedString(
            markdown: $0,
            options: .init(interpretedSyntax: .full)
        ) }
        return (try? parse(text)) ?? AttributedString(text)
    }

    static func mediaPlaceholder(for kind: MediaStore.Kind) -> String {
        switch kind {
        case .image: return String(localized: "Bild nicht verfügbar")
        case .videoURL: return String(localized: "Video nicht verfügbar")
        case .file: return String(localized: "Datei nicht verfügbar")
        }
    }

    static func toolVisualState(
        for call: ToolCallData,
        messages: [ChatMessage],
        isBusy: Bool
    ) -> ChatToolVisualState {
        guard let result = messages.last(where: {
            $0.role == .tool && $0.toolCallId == call.id
        }) else {
            return isBusy ? .active : .failed
        }
        return toolResultState(result.text)
    }

    static func toolResultState(_ text: String) -> ChatToolVisualState {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let failurePrefixes = [
            "error:",
            "blocked:",
            "search failed:",
            "fetch failed:",
            "bildgenerierung fehlgeschlagen",
            "bildgenerierung:",
            "bildgenerierung ist",
            "bildgenerierung abgelehnt",
            "kein bild-anbieter",
            "das bild konnte nicht gespeichert",
            "das erzeugte bild ließ sich nicht laden",
            "das bild-modell",
            "der anbieter hat",
            "dieser anbieter bietet",
            "bilddaten des anbieters",
            "unter der bild-url",
            "die adresse des bild-anbieters"
        ]
        return failurePrefixes.contains(where: value.hasPrefix) ? .failed : .completed
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
                        VStack(spacing: 0) {
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
                                allMessages: session.messages,
                                onPreviewMedia: { mediaPreviewRoute = $0 },
                                isBusy: session.busy,
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
                        // The clearance is part of the scroll content. The
                        // final marker therefore measures and targets the true
                        // bottom, including the space below the composer.
                        Color.clear
                            .frame(height: inputBarHeight + composerLift + 16)
                        Color.clear
                            .frame(height: 1)
                            .id("chat-bottom-sentinel")
                    }
                    .padding(.horizontal, Theme.space3)
                    .padding(.top, Theme.space2)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ChatBottomSentinelKey.self,
                                value: geometry.frame(in: .named("chat-scroll")).maxY
                            )
                            .preference(
                                key: ChatContentHeightKey.self,
                                value: geometry.size.height
                            )
                            .preference(
                                key: ChatContentTopKey.self,
                                value: geometry.frame(in: .named("chat-scroll")).minY
                            )
                        }
                    )
                    .animation(
                        Theme.Motion.preferSpring(Theme.Motion.soft, reduceMotion: reduceMotion),
                        value: visibleMessages.count
                    )
                }
                .accessibilityIdentifier("chat-transcript")
                .coordinateSpace(name: "chat-scroll")
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ChatViewportHeightKey.self,
                            value: geometry.size.height
                        )
                    }
                )
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
                    requestScrollToLatestIfNeeded(proxy)
                }
                .onChange(of: visibleMessages.last?.text) {
                    requestScrollToLatestIfNeeded(proxy)
                }
                .onChange(of: session.statusLine) {
                    guard session.statusLine != nil else { return }
                    requestScrollToLatestIfNeeded(proxy)
                }
                .onChange(of: scrollToLatestRequest) {
                    scrollToLatest(proxy)
                }
                    .onPreferenceChange(ChatBottomSentinelKey.self) { value in
                        bottomSentinelBottom = value
                        updateScrollPosition()
                    }
                .onPreferenceChange(ChatContentTopKey.self) { value in
                    scrollContentTop = value
                    updateScrollPosition()
                }
                .onPreferenceChange(ChatContentHeightKey.self) { value in
                    scrollContentHeight = value
                    updateScrollPosition()
                }
                .onPreferenceChange(ChatViewportHeightKey.self) { value in
                    scrollViewportHeight = value
                    updateScrollPosition()
                }
                .overlay(alignment: .bottomTrailing) {
                    if showJumpToLatest {
                        Button {
                            scrollToLatest(proxy)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.body.weight(.bold))
                                .frame(width: 42, height: 42)
                                .background(Color(.systemBackground), in: Circle())
                                .overlay(Circle().stroke(Color.secondary.opacity(0.22)))
                        }
                        .accessibilityIdentifier("jump-to-latest")
                        .accessibilityLabel(String(localized: "Zu den neuesten Nachrichten"))
                        .padding(.trailing, Theme.space3)
                        .padding(.bottom, inputBarHeight + composerLift + 20)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
#if DEBUG
                .overlay(alignment: .topTrailing) {
                    if uiTestScrollFixtureEnabled {
                        VStack(alignment: .trailing, spacing: 4) {
                            Button {
                                deliverUITestScrollFixtureContent()
                            } label: {
                                Image(systemName: "arrow.down.message")
                            }
                            if uiTestFixtureDelivered {
                                Text("fixture-content-delivered")
                                    .font(.caption2)
                                    .accessibilityIdentifier("ui-test-content-delivered")
                            }
                        }
                        .accessibilityIdentifier("ui-test-deliver-content")
                        .accessibilityLabel("Fixture-Inhalt liefern")
                        .padding(.trailing, Theme.space3)
                        .padding(.top, Theme.space2)
                    }
                }
#endif

                .scrollDismissesKeyboard(.immediately)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onAppear {
            stageIntentTextIfNeeded()
            loadUITestAttachmentFixtureIfNeeded()
#if DEBUG
            loadUITestConversationFixturesIfNeeded()
#endif
        }
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
        .sheet(item: $mediaPreviewRoute) { route in
            ChatMediaGallery(route: route)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .onChange(of: photoItems) { _, items in
            importPhotos(items)
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
        .accessibilityIdentifier("editing-banner")
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
            attachments: $attachments,
            photoItems: $photoItems,
            focus: $composerFocused,
            placeholder: isEditingApp ? String(localized: "Änderung beschreiben…") : String(localized: "Nachricht"),
            isBusy: session.busy,
            canSend: !attachmentImportState.isImporting
                && (!sanitizedInput.isEmpty || !attachments.isEmpty),
            onSend: send,
            onStop: {
                Theme.Haptics.send()
                session.stop()
            },
            onPickFile: { showFileImporter = true }
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
        let pendingAttachments = attachments
        guard !attachmentImportState.isImporting else { return }
        guard !text.isEmpty || !pendingAttachments.isEmpty else {
            if PlainPasteboard.looksLikePasteboardArtifact(input) {
                session.errorMessage = String(localized: "Zwischenablage war RTF/RTFD (kein Klartext). Nochmal als Text kopieren.")
                input = ""
            }
            return
        }
        Theme.Haptics.send()
#if DEBUG
        if runUITestDelayedToolFixtureIfNeeded(text) {
            input = ""
            attachments = []
            photoItems = []
            scrollToLatestRequest += 1
            return
        }
#endif
        session.send(text, attachments: pendingAttachments, settings: settingsStore.settings)
        input = ""
        attachments = []
        photoItems = []
        attachmentImportState.invalidate()
        scrollToLatestRequest += 1
        Analytics.track("chat_send")
    }

    private func loadUITestAttachmentFixtureIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["AIITY_UI_TEST_ATTACHMENTS"] == "1",
              attachments.isEmpty else { return }
        attachments = [ChatAttachment(
            mediaId: "ui-test-attachment",
            filename: "fixture.png",
            mimeType: "image/png",
            kind: .image
        )]
        #endif

    }

#if DEBUG
    private var uiTestScrollFixtureEnabled: Bool {
        ProcessInfo.processInfo.environment["AIITY_UI_TEST_SCROLL_FIXTURE"] == "1"
    }

    private func loadUITestConversationFixturesIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard session.messages.isEmpty else { return }

        if uiTestScrollFixtureEnabled {
            var fixture: [ChatMessage] = []
            for index in 0..<12 {
                fixture.append(ChatMessage(role: .user, text: "fixture-user-\(index)"))
                fixture.append(ChatMessage(
                    role: .assistant,
                    text: index == 5 ? "fixture-anchor" : "fixture-message-\(index)"
                ))
            }
            fixture.append(ChatMessage(role: .assistant, text: "fixture-latest"))
            session.messages = fixture
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                scrollToLatestRequest += 1
            }
            return
        }

        guard environment["AIITY_UI_TEST_IMAGE_ATTACHMENT"] == "1",
              let data = Data(base64Encoded: Self.uiTestPNGBase64),
              let mediaId = MediaStore.save(data: data, filename: "fixture.png", mimeType: "image/png") else {
            return
        }
        session.messages = [ChatMessage(
            role: .user,
            text: "attached fixture",
            attachments: [ChatAttachment(
                mediaId: mediaId,
                filename: "fixture.png",
                mimeType: "image/png",
                kind: .image
            )]
        )]
    }

    private func deliverUITestScrollFixtureContent() {
        guard uiTestScrollFixtureEnabled, !uiTestFixtureDelivered else { return }
        uiTestFixtureDelivered = true
        session.messages.append(ChatMessage(role: .assistant, text: "fixture-new-content"))
    }

    private func runUITestDelayedToolFixtureIfNeeded(_ text: String) -> Bool {
        guard ProcessInfo.processInfo.environment["AIITY_UI_TEST_DELAYED_TOOL"] == "1",
              text == "fixture delayed tool" else { return false }

        let call = ToolCallData(
            id: "ui-test-delayed-tool",
            name: "generate_image",
            argumentsJSON: "{\"prompt\":\"fixture\"}"
        )
        session.messages.append(ChatMessage(role: .user, text: text))
        session.messages.append(ChatMessage(role: .assistant, text: "", toolCalls: [call]))
        session.busy = true
        session.statusLine = String(localized: "Läuft")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            session.messages.append(ChatMessage(
                role: .tool,
                text: "Bild erstellt",
                toolCallId: call.id,
                toolName: call.name
            ))
            session.messages.append(ChatMessage(role: .assistant, text: "fixture tool complete"))
            session.busy = false
            session.statusLine = nil
        }
        return true
    }

    private static let uiTestPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
#endif

    private func updateScrollPosition() {
        let contentBottom = Self.trueContentBottom(
            contentTop: scrollContentTop,
            contentHeight: scrollContentHeight,
            sentinelBottom: bottomSentinelBottom
        )
        guard scrollViewportHeight > 0, contentBottom > 0 else { return }
        isNearBottom = Self.isNearBottom(
            contentBottom: contentBottom,
            viewportBottom: scrollViewportHeight
        )
        showJumpToLatest = !isNearBottom
    }

    private func requestScrollToLatestIfNeeded(_ proxy: ScrollViewProxy) {
        guard isNearBottom else {
            showJumpToLatest = true
            return
        }
        scrollToLatest(proxy)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard visibleMessages.last != nil || session.statusLine != nil else { return }
        withAnimation(
            Theme.Motion.preferSpring(Theme.Motion.scroll, reduceMotion: reduceMotion)
        ) {
            proxy.scrollTo("chat-bottom-sentinel", anchor: .bottom)
        }
        showJumpToLatest = false
    }

    private func retryLastUserMessage() {
        guard let last = session.messages.last(where: { $0.role == .user }) else { return }
        session.errorMessage = nil
        session.send(last.text, attachments: last.attachments, settings: settingsStore.settings)
        Analytics.track("chat_retry")
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        let token = attachmentImportState.beginBatch(count: items.count)
        for item in items {
            Task { @MainActor in
                defer { attachmentImportState.finish(token) }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let type = item.supportedContentTypes.first else {
                    session.errorMessage = String(localized: "Foto konnte nicht geladen werden.")
                    return
                }
                guard attachmentImportState.accepts(token) else { return }
                let mimeType = type.preferredMIMEType ?? "image/jpeg"
                guard let mediaId = MediaStore.save(data: data, filename: "photo", mimeType: mimeType) else {
                    session.errorMessage = String(localized: "Foto konnte nicht gespeichert werden.")
                    return
                }
                let extensionName = type.preferredFilenameExtension ?? "jpg"
                attachments.append(ChatAttachment(
                    mediaId: mediaId,
                    filename: "photo-\(mediaId.prefix(8)).\(extensionName)",
                    mimeType: mimeType,
                    kind: .image
                ))
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            session.errorMessage = String(localized: "Datei konnte nicht geladen werden.")
            return
        }
        let token = attachmentImportState.beginBatch(count: urls.count)
        for url in urls {
            Task { @MainActor in
                defer { attachmentImportState.finish(token) }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    session.errorMessage = String(localized: "Datei konnte nicht gelesen werden.")
                    return
                }
                let type = UTType(filenameExtension: url.pathExtension)
                let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
                guard let mediaId = MediaStore.save(
                    data: data,
                    filename: url.lastPathComponent,
                    mimeType: mimeType
                ) else {
                    session.errorMessage = String(localized: "Datei konnte nicht gespeichert werden.")
                    return
                }
                guard attachmentImportState.accepts(token) else { return }
                attachments.append(ChatAttachment(
                    mediaId: mediaId,
                    filename: url.lastPathComponent,
                    mimeType: mimeType,
                    kind: type?.conforms(to: .image) == true ? .image : .file
                ))
            }
        }
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

private struct ChatBottomSentinelKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatContentTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
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
    let allMessages: [ChatMessage]
    let onPreviewMedia: (ChatMediaPreviewRoute) -> Void
    let isBusy: Bool
    var showTyping: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var bubbleText: String {
        message.role == .assistant ? ChatView.strippingHTMLFence(from: message.text) : message.text
    }

    private var imageMediaIds: [String] {
        message.mediaIds.filter {
            if case .image = MediaStore.kind(of: $0) { return true }
            return false
        }
            + message.attachments
                .filter { $0.kind == .image }
                .map(\.mediaId)
    }

    private var previewRoute: ChatMediaPreviewRoute? {
        guard let selectedId = imageMediaIds.first else { return nil }
        return ChatMediaPreviewRoute(mediaIds: imageMediaIds, selectedId: selectedId)
    }

    var body: some View {
        switch message.role {
        case .tool:
            ToolChip(
                name: message.toolName ?? "tool",
                text: message.text,
                state: ChatView.toolResultState(message.text)
            )
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
                            ToolChip(
                                name: call.name,
                                text: toolSummary(call),
                                state: ChatView.toolVisualState(
                                    for: call,
                                    messages: allMessages,
                                    isBusy: isBusy
                                )
                            )
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
                        GeneratedMediaView(
                            mediaId: mediaId,
                            previewRoute: previewRoute,
                            onPreview: onPreviewMedia
                        )
                    }
                    ForEach(message.attachments) { attachment in
                        ChatAttachmentBubble(
                            attachment: attachment,
                            previewRoute: previewRoute,
                            onPreview: onPreviewMedia
                        )
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
        Text(ChatView.markdownAttributedString(text))
    }
}

private struct ChatAttachmentBubble: View {
    let attachment: ChatAttachment
    let previewRoute: ChatMediaPreviewRoute?
    let onPreview: (ChatMediaPreviewRoute) -> Void

    var body: some View {
        if attachment.kind == .image,
           let data = MediaStore.data(for: attachment.mediaId),
           let image = UIImage(data: data) {
            Button {
                if let previewRoute { onPreview(previewRoute) }
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-attachment-preview-\(attachment.mediaId)")
            .accessibilityLabel(String(localized: "Bildvorschau öffnen"))
        } else {
            Label(
                attachment.kind == .image
                    ? ChatView.mediaPlaceholder(for: .image)
                    : attachment.filename,
                systemImage: attachment.kind == .image ? "photo.badge.exclamationmark" : "doc"
            )
                .font(.footnote)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                .accessibilityLabel(
                    attachment.kind == .image
                        ? ChatView.mediaPlaceholder(for: .image)
                        : attachment.filename
                )
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
    let state: ChatToolVisualState

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
            if state == .active {
                ProgressView().controlSize(.mini)
            } else if state == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if state != .active, !text.isEmpty {
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
        .accessibilityIdentifier("chat-tool-\(name)")
        .accessibilityValue(toolStateLabel)
        .accessibilityLabel("\(label): \(toolStateLabel), \(text)")
    }

    private var toolStateLabel: String {
        switch state {
        case .active: return String(localized: "Läuft")
        case .completed: return String(localized: "Abgeschlossen")
        case .failed: return String(localized: "Fehlgeschlagen")
        }
    }
}

private struct GeneratedMediaView: View {
    let mediaId: String
    let previewRoute: ChatMediaPreviewRoute?
    let onPreview: (ChatMediaPreviewRoute) -> Void

    var body: some View {
        switch MediaStore.kind(of: mediaId) {
        case .image:
            if let data = MediaStore.imageData(for: mediaId), let image = UIImage(data: data) {
                Button {
                    if let previewRoute { onPreview(previewRoute) }
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("generated-image")
                .accessibilityLabel(String(localized: "Bildvorschau öffnen"))
            } else {
                missingMedia(kind: .image)
            }
        case .videoURL:
            if let url = MediaStore.videoURL(for: mediaId) {
                Link(destination: url) {
                    Label("Video ansehen", systemImage: "play.rectangle.fill")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                }
            } else {
                missingMedia(kind: .videoURL)
            }
        case .file:
            missingMedia(kind: .file)
        }
    }

    private func missingMedia(kind: MediaStore.Kind) -> some View {
        Label(
            ChatView.mediaPlaceholder(for: kind),
            systemImage: "photo.badge.exclamationmark"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .accessibilityIdentifier("media-missing")
    }
}

private struct ChatMediaGallery: View {
    let route: ChatMediaPreviewRoute
    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: String

    init(route: ChatMediaPreviewRoute) {
        self.route = route
        _selectedId = State(initialValue: route.selectedId)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedId) {
                ForEach(route.mediaIds, id: \.self) { mediaId in
                    Group {
                        if let data = MediaStore.imageData(for: mediaId),
                           let image = UIImage(data: data) {
                            ScrollView([.horizontal, .vertical]) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .padding(Theme.space3)
                            }
                        } else {
                            VStack(spacing: Theme.space2) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.title2)
                                Text(String(localized: "Bild nicht verfügbar"))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .tag(mediaId)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: route.mediaIds.count > 1 ? .automatic : .never))
            .accessibilityIdentifier("media-preview")
            .navigationTitle(String(localized: "Bild"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Schließen")) { dismiss() }
                        .accessibilityIdentifier("media-preview-close")
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
