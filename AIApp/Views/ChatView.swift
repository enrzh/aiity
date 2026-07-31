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
    /// Measured height of the floating input bubble — drives the scroll
    /// clearance so a multi-line input never overlaps the last message.
    @State private var inputBarHeight: CGFloat = 64
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        if model.isEmpty { return "Modell" }
        let short = model.count > 18 ? String(model.prefix(16)) + "…" : model
        return short
    }

    private var needsSetup: Bool {
        let s = settingsStore.settings
        if s.preset.dialect == .mlx { return false }
        if ConnectionProbe.isLocalStyle(s.presetId) {
            return s.effectiveBaseURL.isEmpty || s.effectiveModel.isEmpty
        }
        return s.effectiveModel.isEmpty
    }

    private var isEditingApp: Bool { session.editingContext != nil }

    var body: some View {
        VStack(spacing: 0) {
            if let ctx = session.editingContext {
                editingBanner(ctx)
            }

            // Pinned under the header rather than trailing the transcript: the
            // conversation keeps scrolling underneath while the app you are
            // building stays reachable, instead of being pushed off-screen by
            // the next few messages.
            if let draft = session.draftMiniApp {
                MiniAppCard(
                    draft: draft,
                    isStreaming: session.busy,
                    onPreview: { previewDraft = draft },
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
                .padding(.bottom, Theme.space2)
                .transition(.move(edge: .top).combined(with: .opacity))
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
                            .id(message.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        if session.busy, session.statusLine != nil {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .accessibilityLabel(session.statusLine ?? "Arbeitet")
                            .id("status-line")
                        }
                        // Another round is a deliberate tap: the agents never
                        // decide to keep talking (and spending) on their own.
                        if session.activeThreadIsGroup, !session.busy, !visibleMessages.isEmpty {
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
                    .padding(.bottom, inputBarHeight + 16)
                    .animation(
                        Theme.Motion.preferSpring(Theme.Motion.soft, reduceMotion: reduceMotion),
                        value: visibleMessages.count
                    )
                }
                // Count as well as text: a NEW message (another agent taking
                // its turn, a tool result) left the view parked where it was,
                // because only the last message's text was being watched.
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
        }
        .onPreferenceChange(InputBarHeightKey.self) { inputBarHeight = $0 }
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
                    showQuickProvider = true
                } label: {
                    Image(systemName: "cpu")
                }
                .accessibilityIdentifier("chat-provider")
                .accessibilityLabel("Modell: \(activeModelLabel)")
                .accessibilityHint("Anbieter und Modell wählen")

                // Skills used to hide behind an overflow menu whose only other
                // entry was the provider — which already has its own button.
                Button {
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
            NavigationStack {
                ConnectionsView()
            }
            .environmentObject(settingsStore)
            .environmentObject(accountStore)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSkills) {
            NavigationStack {
                SkillsView()
            }
            .presentationDetents([.large, .medium])
            .presentationDragIndicator(.visible)
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
            message: "Noch kein Modell — oben tippen.",
            kind: .info
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Image(systemName: isEditingApp ? "wand.and.stars" : "sparkles")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(isEditingApp ? "Was ändern?" : "Was soll ich bauen?")
                .font(.title2.bold())
            SuggestionList(suggestions: isEditingApp ? [
                "Dunkleres Design",
                "Bearbeiten & Löschen",
                "Anderes Icon",
                "Netzwerk erlauben",
            ] : [
                "Trinkgeld-Rechner",
                "Todo-Liste",
                "Pomodoro-Timer",
                "Tech-News heute",
            ]) { suggestion in
                input = suggestion
                send()
            }
        }
        .padding(.top, Theme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Floating input: a text-field bubble and a round send/stop bubble — no bar.
    private var inputBar: some View {
        ChatComposer(
            text: $input,
            placeholder: isEditingApp ? "Änderung beschreiben…" : "Nachricht",
            isBusy: session.busy,
            canSend: !sanitizedInput.isEmpty,
            onSend: send,
            onStop: session.stop
        ) { newValue in
            if PlainPasteboard.looksLikePasteboardArtifact(newValue) {
                input = PlainPasteboard.plainText() ?? ""
            }
        }
    }

    private var sanitizedInput: String {
        PlainPasteboard.sanitize(input) ?? ""
    }

    private func send() {
        let text = sanitizedInput
        guard !text.isEmpty else {
            if PlainPasteboard.looksLikePasteboardArtifact(input) {
                session.errorMessage = "Zwischenablage war RTF/RTFD (kein Klartext). Nochmal als Text kopieren."
                input = ""
            }
            return
        }
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
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Bubbles

private struct MessageBubble: View {
    let message: ChatMessage
    var showTyping: Bool = false

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
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
                        .accessibilityLabel("Schreibt")
                    } else if !bubbleText.isEmpty {
                        markdownText(bubbleText)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                message.role == .user
                                    ? AnyShapeStyle(Theme.accentGradient)
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
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityIdentifier("generated-image")
            }
        case .videoURL:
            if let url = MediaStore.videoURL(for: mediaId) {
                Link(destination: url) {
                    Label("Video ansehen", systemImage: "play.rectangle.fill")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
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
                Button("Behalten", action: onKeep)
                    .buttonStyle(.borderedProminent)
                    .disabled(isStreaming)
                    .accessibilityIdentifier("keep-app")
            }
        }
        .padding(Theme.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Glass: the card now floats over the scrolling conversation, so it
        // should read as a layer above it rather than another opaque block.
        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}
