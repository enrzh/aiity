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
    @State private var showThreads = false
    @State private var showUpgrade = false
    @State private var showQuickProvider = false
    @State private var showSkills = false
    /// Measured height of the floating input bubble — drives the scroll
    /// clearance so a multi-line input never overlaps the last message.
    @State private var inputBarHeight: CGFloat = 64
    @Environment(\.modelContext) private var modelContext

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

    private var activeModelLabel: String {
        let s = settingsStore.settings
        if s.preset.dialect == .mlx {
            return "MLX · \(s.localModelId.split(separator: "/").last.map(String.init) ?? s.localModelId)"
        }
        let model = s.effectiveModel
        if model.isEmpty { return "\(s.preset.label) · Modell wählen" }
        let short = model.count > 24 ? String(model.prefix(22)) + "…" : model
        return "\(s.preset.label) · \(short)"
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

    private var skillsChipLabel: String {
        let n = SkillStore.enabledCount()
        let imp = SkillStore.enabledImportedCount()
        if n == 0 { return "Skills: aus" }
        if imp > 0 { return "Skills: \(imp) importiert · \(n) aktiv" }
        return "Skills: \(n) aktiv"
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                showQuickProvider = true
            } label: {
                ActiveModelChip(label: activeModelLabel)
            }
            .buttonStyle(.plain)

            Button {
                showSkills = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.caption2)
                    Text(skillsChipLabel)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(SkillStore.enabledImportedCount() > 0 ? Color.accentColor : .secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(Color(.tertiarySystemBackground))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("skills-chip")

            if let ctx = session.editingContext {
                editingBanner(ctx)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if needsSetup {
                            setupBanner
                        }
                        if visibleMessages.isEmpty {
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
                        }
                        if let status = session.statusLine {
                            HStack(spacing: 8) {
                                if status != "Gestoppt" {
                                    ProgressView().controlSize(.small)
                                }
                                Text(status)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                            .id("status-line")
                        }
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
                            .id("mini-app-card")
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
                                        Label("Erneut senden", systemImage: "arrow.clockwise")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .id("error-banner")
                        }
                    }
                    .padding()
                    // Clearance so the last message can scroll clear of the
                    // floating input bubble (which overlays the content). Tracks
                    // the measured bubble height so a 6-line input never overlaps.
                    .padding(.bottom, inputBarHeight + 16)
                }
                .onChange(of: visibleMessages.last?.text) {
                    if let lastId = visibleMessages.last?.id {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: session.statusLine) {
                    if session.statusLine != nil {
                        proxy.scrollTo("status-line", anchor: .bottom)
                    }
                }
                .onChange(of: session.draftMiniApp) {
                    if session.draftMiniApp != nil {
                        proxy.scrollTo("mini-app-card", anchor: .bottom)
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
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showThreads = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .disabled(session.busy)
                .accessibilityIdentifier("chat-threads")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    session.newThread()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(session.busy)
                .accessibilityIdentifier("chat-new")
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
        .sheet(isPresented: $showThreads) {
            ThreadsSheet()
        }
        .sheet(isPresented: $showUpgrade) {
            UpgradeModal(
                title: "Mini-App-Limit",
                message: FreeTier.miniAppLimitMessage,
                onDismiss: { showUpgrade = false }
            )
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
        let kb = max(1, ctx.html.utf8.count / 1024)
        return HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bearbeiten: \(ctx.name)")
                    .font(.subheadline.weight(.semibold))
                Text("Quellcode an KI übergeben (\(kb) KB) — Änderungen beschreiben, „Behalten“ speichert.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Ende") {
                session.editingContext = nil
                session.persistPublic()
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
    }

    private var setupBanner: some View {
        BannerView(
            message: "Noch kein nutzbares Modell. Tippe oben auf den Anbieter oder öffne Mehr → KI-Anbieter.",
            kind: .info
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: isEditingApp ? "wand.and.stars" : "sparkles")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
            Text(isEditingApp ? "Was soll ich an der App ändern?" : "Was soll ich bauen?")
                .font(.title2.bold())
            Text(isEditingApp
                 ? "Feature, Design, Icon oder z. B. Netzwerk-Fähigkeit beschreiben."
                 : "Frage stellen oder Mini-App beschreiben. Web-Recherche und Skills laufen im Hintergrund.")
                .foregroundStyle(.secondary)
            SuggestionList(suggestions: isEditingApp ? [
                "Mach das Design dunkler und moderner",
                "Füge Bearbeiten und Löschen hinzu",
                "Ändere das Icon und den Titel",
                "Erlaube Netzwerk (capability: network)",
            ] : [
                "Bau mir einen Trinkgeld-Rechner",
                "Einfache Todo-Liste mit Dark Mode",
                "Pomodoro-Timer mit Erinnerung",
                "Was ist heute in den Tech-News?",
            ]) { suggestion in
                input = suggestion
                send()
            }
        }
        .padding(.top, 24)
    }

    // Floating input: a text-field bubble and a round send/stop bubble — no bar.
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(isEditingApp ? "Änderung beschreiben…" : "Nachricht", text: $input, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.05))
                )
                .shadow(color: .black.opacity(0.06), radius: 7, y: 2)
                .onSubmit(send)
                .disabled(session.busy)
                .accessibilityIdentifier("chat-input")
                .onChange(of: input) { _, newValue in
                    // Block RTFD / shared-pasteboard path dumps from rich paste.
                    if PlainPasteboard.looksLikePasteboardArtifact(newValue) {
                        input = PlainPasteboard.plainText() ?? ""
                    }
                }
            if session.busy {
                Button { session.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.red, in: Circle())
                        .shadow(color: .red.opacity(0.35), radius: 6, y: 2)
                }
                .accessibilityIdentifier("chat-stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(sanitizedInput.isEmpty ? Color.secondary : .white)
                        .frame(width: 40, height: 40)
                        .background(
                            sanitizedInput.isEmpty
                                ? AnyShapeStyle(Color(.tertiarySystemFill))
                                : AnyShapeStyle(Theme.accentGradient),
                            in: Circle()
                        )
                        .shadow(color: sanitizedInput.isEmpty ? .clear : Theme.accent.opacity(0.35), radius: 6, y: 2)
                }
                .disabled(sanitizedInput.isEmpty)
                .accessibilityIdentifier("chat-send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
        guard FreeTier.canSaveMiniApp(currentCount: savedApps.count) else {
            showUpgrade = true
            Analytics.track("freemium_gate", ["kind": "miniapp"])
            return
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
                    if !message.toolCalls.isEmpty {
                        ForEach(message.toolCalls) { call in
                            ToolChip(name: call.name, text: toolSummary(call), pending: showTyping && bubbleText.isEmpty)
                        }
                    }
                    if showTyping {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Schreibt…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else if !bubbleText.isEmpty {
                        markdownText(bubbleText)
                            .textSelection(.enabled)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 11)
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
        case "generate_video": return args["prompt"] as? String ?? "Video"
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
        case "generate_video": return "video"
        default: return "wrench.and.screwdriver"
        }
    }

    private var label: String {
        switch name {
        case "web_search": return "Web"
        case "fetch_url": return "Seite"
        case "generate_image": return "Bild"
        case "generate_video": return "Video"
        default: return name
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    if pending {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MiniAppIconView(emoji: draft.emoji, iconSymbol: draft.iconSymbol, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(draft.name).font(.headline)
                        if isStreaming {
                            ProgressView().controlSize(.mini)
                            Text("live")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(draft.filesJSON == "{}" || draft.filesJSON.isEmpty ? "Mini-App" : "Multi-File")
                        Text("·")
                        Text(MiniAppCapability.from(html: draft.html).label)
                        if isStreaming {
                            Text("·")
                            Text("~\(draft.html.count) Zeichen")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button("Vorschau", action: onPreview)
                    .buttonStyle(.bordered)
                    .disabled(isStreaming && draft.html.count < 200)
                    .accessibilityIdentifier("preview-app")
                if let onEditAI {
                    Button(action: onEditAI) {
                        Label("KI", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isStreaming)
                }
                Button("Behalten", action: onKeep)
                    .buttonStyle(.borderedProminent)
                    .disabled(isStreaming)
                    .accessibilityIdentifier("keep-app")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
