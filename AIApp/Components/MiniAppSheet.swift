import SwiftUI
import SwiftData
import UIKit

/// Sheet hosting a sandboxed mini-app. Chrome: **AI · Title · Done**.
/// Tapping AI dismisses and opens Chat linked to this app for further edits.
struct MiniAppSheet: View {
    let appId: String
    let name: String
    let html: String
    /// Saved library id when known — AI button wires chat to this app.
    var libraryId: UUID? = nil
    var emoji: String = "✨"
    var iconSymbol: String? = nil
    /// Called after dismiss when user wants AI edits (host switches to Chat tab).
    var onEditWithAI: (() -> Void)? = nil
    /// Follow `session.draftMiniApp` as the model writes it, so a preview
    /// opened mid-generation keeps building. Only the chat draft card sets
    /// this; a saved app has no stream to follow.
    var followsDraft: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var session: ChatSession
    @Environment(\.openChatTab) private var openChatTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var browserState = MiniAppBrowserState()
    @State private var effectiveCapability: MiniAppCapability = .offline
    @State private var pendingDeclared: MiniAppCapability = .offline
    @State private var pendingHost: String?
    @State private var pendingHostDraft = ""
    @State private var showConsent = false
    @State private var showHistory = false
    /// Set by a "Verlauf" restore, replacing the `html` this sheet was opened
    /// with — the runner's `updateUIView` reloads on the changed document.
    @State private var restoredHTML: String?
    /// The live draft while it streams. Only ever moves forward: "Behalten"
    /// clears `session.draftMiniApp`, and falling back to the snapshot this
    /// sheet was opened with would rewind the preview to a half-written app.
    @State private var streamedHTML: String?
    /// The draft's title as it streams. It arrives with the document's
    /// `<title>`, so a preview opened early is titled "Mini-App" until then —
    /// and the consent prompt, which runs only once the stream ends, must name
    /// the app rather than that placeholder.
    @State private var streamedName: String?

    private var activeHTML: String { restoredHTML ?? streamedHTML ?? html }
    private var activeName: String { streamedName ?? name }

    /// True while `activeHTML` is a document the model has not finished. A
    /// restore replaces the document outright, so it ends the stream.
    private var isStreamingDraft: Bool {
        followsDraft && session.busy && restoredHTML == nil
    }

    var body: some View {
        AppSheet(detents: [.large]) {
            runnerContent
        }
    }

    private var runnerContent: some View {
        NavigationStack {
            MiniAppRunnerView(
                appId: appId,
                html: activeHTML,
                capability: effectiveCapability,
                appName: activeName,
                browserState: browserState,
                isStreamingDraft: isStreamingDraft,
                streamPatchInterval: reduceMotion
                    ? MiniAppPreviewStream.reducedMotionPatchInterval
                    : MiniAppPreviewStream.minimumPatchInterval
            )
            // Rebuild the web view when consent flips the tier.
            //
            // A WKWebViewConfiguration's websiteDataStore is immutable after
            // creation, and the runner picks the persistent per-app store from
            // the ALREADY-granted consent. On a first open that grant does not
            // exist yet (the alert below runs after makeUIView), so the web view
            // was ephemeral and the very first login's cookies were thrown away
            // on close. Changing identity here tears that web view down and
            // re-enters makeUIView with the grant written.
            //
            // The identity change is scoped to the runner: `onAppear` below sits
            // outside it, so the consent alert still resolves exactly once.
            .id(effectiveCapability)
            // The web view is non-opaque; keep a solid surface behind user
            // content so the sheet's glass background never bleeds into an
            // app that sets no background of its own.
            .background(Color(.systemBackground).ignoresSafeArea())
            .ignoresSafeArea(edges: .bottom)
            .onAppear {
                let live = followsDraft ? session.draftMiniApp : nil
                if let live { adopt(live) }
                resolveCapability(for: live?.html ?? activeHTML)
            }
            .onChange(of: session.draftMiniApp?.html) { _, streamed in
                guard followsDraft, streamed != nil, let draft = session.draftMiniApp else { return }
                adopt(draft)
            }
            .onChange(of: session.busy) { _, busy in
                // The tier is read ONCE, off the finished document. The
                // `<!-- capability: … -->` comment can arrive at any point in
                // the stream, and re-resolving per chunk would raise the
                // consent alert over and over — and tear the runner down under
                // the user's finger through `.id(effectiveCapability)`.
                //
                // The last chunk and `busy` land in the SAME update pass, so
                // the @State mirror above is still one pass behind here. Read
                // the document off the session rather than waiting for it.
                guard followsDraft, !busy else { return }
                resolveCapability(for: session.draftMiniApp?.html ?? activeHTML)
            }
            .alert("Internetzugriff erlauben?", isPresented: $showConsent) {
                if pendingDeclared != .offline, pendingHost == nil {
                    TextField("HTTPS-Host", text: $pendingHostDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button("Nur offline", role: .cancel) { effectiveCapability = .offline }
                Button("Erlauben") {
                    let approvedHost = pendingHost
                        ?? NetworkTargetValidator.normalizeHost(pendingHostDraft)
                    guard pendingDeclared == .offline || approvedHost != nil else { return }
                    MiniAppConsent.allow(
                        appId: appId,
                        capability: pendingDeclared,
                        hosts: approvedHost.map { [$0] } ?? []
                    )
                    effectiveCapability = pendingDeclared
                }
                .disabled(pendingDeclared != .offline
                    && pendingHost == nil
                    && NetworkTargetValidator.normalizeHost(pendingHostDraft) == nil)
            } message: {
                // Be explicit that access is two-way: these tiers can also SEND
                // whatever the app holds to a server, not just load data.
                let what = pendingDeclared == .browser
                    ? String(localized: "Webseiten öffnen und laden")
                    : String(localized: "Daten aus dem Internet laden")
                Text(String(localized: "Die App „\(activeName)“ möchte \(what) (\(pendingDeclared.label)). Sie kann dabei auch Daten an fremde Server senden. Nur erlauben, wenn du dieser App vertraust."))
            }
            .navigationTitle(activeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A browser app that followed a link needs a way out of it.
                // The WebKit edge-swipe exists too, but inside a presented
                // sheet the system's own edge handling can swallow it — an
                // explicit control is the one that always works.
                ToolbarItem(placement: .topBarLeading) {
                    if browserState.canGoBack {
                        Button {
                            browserState.goBack()
                        } label: {
                            Image(systemName: "chevron.backward")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("Zurück")
                        .accessibilityIdentifier("miniapp-back")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        openAIEdit()
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .accessibilityLabel("Mit KI bearbeiten")
                    .accessibilityIdentifier("miniapp-ai-edit")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        MiniAppIconView(emoji: emoji, iconSymbol: iconSymbol, size: 22)
                        Text(activeName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(
                            item: MiniAppShareItem(
                                name: activeName,
                                emoji: emoji,
                                iconSymbol: iconSymbol,
                                html: activeHTML
                            ),
                            preview: SharePreview(activeName)
                        ) {
                            Label("Teilen", systemImage: "square.and.arrow.up")
                        }
                        // Remix and history need a saved record — a chat
                        // preview has neither an id to duplicate nor revisions.
                        if libraryId != nil {
                            Button {
                                remix()
                            } label: {
                                Label("Remix", systemImage: "square.on.square")
                            }
                            .accessibilityIdentifier("miniapp-remix")
                            Button {
                                showHistory = true
                            } label: {
                                Label("Verlauf", systemImage: "clock.arrow.circlepath")
                            }
                            .accessibilityIdentifier("miniapp-history")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Weitere Aktionen")
                    .accessibilityIdentifier("miniapp-menu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("miniapp-done")
                }
            }
            .sheet(isPresented: $showHistory) {
                if let libraryId {
                    MiniAppRevisionSheet(appId: libraryId) { html in
                        restoredHTML = html
                        resolveCapability()
                    }
                }
            }
        }
    }

    /// Take on the model's current draft. Called for every published chunk, so
    /// it must never move backwards — the placeholder title the parser returns
    /// before `<title>` is written would otherwise replace a real one.
    private func adopt(_ draft: MiniAppDraft) {
        streamedHTML = draft.html
        if !draft.name.isEmpty, draft.name != "Mini-App" { streamedName = draft.name }
    }

    /// Offline apps run immediately; a network/browser app runs offline until
    /// the user consents (once per app). Re-run after a "Verlauf" restore —
    /// the restored document may declare a different tier.
    private func resolveCapability(for document: String? = nil) {
        // A document the model is still writing runs at the most restrictive
        // tier, and asks for nothing. Consent must be given for what the app
        // finally IS: the first kilobytes are not something a user can judge,
        // and the code that would use the grant has not been written yet. The
        // stream ending re-enters here and prompts then, once.
        guard !isStreamingDraft else {
            effectiveCapability = .offline
            return
        }
        let source = document ?? activeHTML
        let declared = MiniAppCapability.from(html: source)
        let host = WebAppBuilder.openTarget(in: source).flatMap {
            NetworkTargetValidator.normalizeHost($0.host ?? "")
        }
        if MiniAppConsent.isAllowed(appId: appId, declared: declared),
           host == nil || MiniAppConsent.hosts(appId: appId).contains(host!) {
            effectiveCapability = declared
        } else {
            effectiveCapability = .offline
            pendingDeclared = declared
            pendingHost = host
            pendingHostDraft = ""
            showConsent = true
        }
    }

    private func openAIEdit() {
        if let libraryId {
            session.startEditing(id: libraryId, name: activeName, html: activeHTML)
        } else {
            session.startEditingDraft(name: activeName, html: activeHTML, emoji: emoji)
        }
        // Drop the web view's keyboard BEFORE the sheet starts dismissing.
        // This path stacks three animations (sheet dismissal, keyboard hide,
        // tab switch) — the race that could leave the chat composer's keyboard
        // inset stale, floating the bar mid-screen with no keyboard visible.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        // Route BEFORE dismissing, and without a timer. The destination is set
        // up underneath a sheet that is still on screen, so the dismissal
        // uncovers a Chat tab that already shows the conversation — nothing has
        // to be timed against the dismissal animation. The old 0.35 s hop also
        // read `openChatTab` out of an @Environment whose view had already been
        // torn down by then, which resolves to the key's no-op default.
        openChatTab()
        onEditWithAI?()
        dismiss()
    }

    /// Same duplicate-then-edit flow as the library tile's Remix action, and
    /// the same keyboard / route-before-dismiss order as `openAIEdit` above —
    /// see the comments there.
    private func remix() {
        guard let libraryId else { return }
        let targetId: UUID = libraryId
        let descriptor = FetchDescriptor<MiniApp>(predicate: #Predicate { $0.id == targetId })
        guard let original = try? modelContext.fetch(descriptor).first else { return }
        let copy = original.remixCopy()
        modelContext.insert(copy)
        session.startEditing(id: copy.id, name: copy.name, html: copy.runnableHTML)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        openChatTab()
        dismiss()
    }
}

/// Compact host manager for a saved mini-app. Changes use the same consent
/// record as first-open approval and the same WebKit cleanup as app deletion.
struct MiniAppPermissionSheet: View {
    let appId: String
    let name: String
    let capability: MiniAppCapability

    @Environment(\.dismiss) private var dismiss
    @State private var hostDraft = ""
    @State private var hosts: [String] = []
    @State private var showHostError = false

    var body: some View {
        AppSheet(detents: [.medium]) {
            NavigationStack {
                List {
                    Section {
                        HStack {
                            TextField("Host oder URL", text: $hostDraft)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                            Button {
                                addHost()
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .disabled(hostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Host erlauben")
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .lineLimit(1)
                            Text("Erlaubte Hosts")
                        }
                    }

                    Section {
                        if hosts.isEmpty {
                            Text("Keine Hosts erlaubt")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(hosts, id: \.self) { host in
                                Text(host)
                            }
                            .onDelete { offsets in
                                for host in offsets.map({ hosts[$0] }) {
                                    _ = MiniAppConsent.revokeHost(appId: appId, host: host)
                                }
                                MiniAppRunnerView.removeSessionStore(for: appId)
                                hosts.remove(atOffsets: offsets)
                            }
                        }
                    }

                    if !hosts.isEmpty {
                        Section {
                            Button("Alle Hosts widerrufen", role: .destructive) {
                                MiniAppConsent.revokeAllHosts(appId: appId)
                                MiniAppRunnerView.removeSessionStore(for: appId)
                                hosts = []
                            }
                        }
                    }

                    Section {
                        Button("Berechtigung vollständig widerrufen", role: .destructive) {
                            MiniAppConsent.revoke(appId: appId)
                            MiniAppRunnerView.removeSessionStore(for: appId)
                            dismiss()
                        }
                    } footer: {
                        Text("Die App muss beim nächsten Öffnen erneut fragen.")
                    }
                }
                .navigationTitle("Netzwerkzugriff")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
                .onAppear { hosts = MiniAppConsent.hosts(appId: appId) }
                .alert("Host nicht erlaubt", isPresented: $showHostError) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("Nur öffentliche HTTPS-Hosts ohne Pfad oder Port können erlaubt werden.")
                }
            }
        }
    }

    private func addHost() {
        guard capability != .offline,
              let normalized = NetworkTargetValidator.normalizeHost(hostDraft) else {
            showHostError = true
            return
        }
        // Adding a host is an explicit approval from this saved-app surface.
        // It also handles apps whose first open was denied, so the add control
        // does not depend on a prior run just to create the consent record.
        if !MiniAppConsent.grantHost(appId: appId, host: normalized) {
            MiniAppConsent.allow(appId: appId, capability: capability, hosts: [normalized])
        }
        hosts = MiniAppConsent.hosts(appId: appId)
        hostDraft = ""
    }
}

/// Version history for a saved mini-app: a plain list of restore points with
/// relative date and size — deliberately no thumbnails, the Pages/Numbers
/// version-browser restraint. Restoring records the CURRENT state as its own
/// revision first, so a restore never destroys anything.
struct MiniAppRevisionSheet: View {
    let appId: UUID
    /// Called with the restored HTML so the open runner reloads it.
    var onRestore: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var revisions: [MiniAppRevisionStore.Revision] = []
    @State private var restoreCandidate: MiniAppRevisionStore.Revision?

    var body: some View {
        AppSheet(detents: [.medium, .large]) {
            NavigationStack {
                List {
                    if revisions.isEmpty {
                        Text("Noch keine Versionen — sie entstehen automatisch, wenn die KI diese App bearbeitet.")
                            .foregroundStyle(.secondary)
                    } else {
                        Section {
                            ForEach(revisions) { revision in
                                Button {
                                    restoreCandidate = revision
                                } label: {
                                    revisionRow(revision)
                                }
                                .accessibilityIdentifier("miniapp-revision")
                            }
                        } footer: {
                            Text("Beim Wiederherstellen wird der aktuelle Stand zuerst als eigene Version gesichert.")
                        }
                    }
                }
                .navigationTitle("Verlauf")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
                .onAppear { revisions = MiniAppRevisionStore.revisions(appId: appId) }
                // Same centered-alert idiom as the library's delete step:
                // replacing the live document deserves an interruption, not a
                // sheet-on-sheet continuation.
                .alert(
                    String(localized: "Version wiederherstellen?"),
                    isPresented: Binding(
                        get: { restoreCandidate != nil },
                        set: { if !$0 { restoreCandidate = nil } }
                    ),
                    presenting: restoreCandidate
                ) { revision in
                    Button("Wiederherstellen") { restore(revision) }
                        .accessibilityIdentifier("miniapp-revision-restore")
                    Button("Abbrechen", role: .cancel) { restoreCandidate = nil }
                } message: { _ in
                    Text("Der aktuelle Stand wird vorher als eigene Version gesichert — es geht nichts verloren.")
                }
            }
        }
    }

    private func revisionRow(_ revision: MiniAppRevisionStore.Revision) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(revision.savedAt, format: .relative(presentation: .named))
                Text(revision.savedAt, format: .dateTime.day().month().year().hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Int64(revision.bytes), format: .byteCount(style: .file))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func restore(_ revision: MiniAppRevisionStore.Revision) {
        defer { restoreCandidate = nil }
        guard let restored = MiniAppRevisionStore.html(appId: appId, revision: revision) else { return }
        let targetId: UUID = appId
        let descriptor = FetchDescriptor<MiniApp>(predicate: #Predicate { $0.id == targetId })
        guard let app = try? modelContext.fetch(descriptor).first else { return }
        // Current state FIRST, as its own revision — a restore must never be
        // the one operation whose starting point cannot be returned to.
        MiniAppRevisionStore.record(appId: appId, html: app.runnableHTML)
        app.html = restored
        // Revisions hold the BUNDLED document, so stale companions must not be
        // inlined a second time on top of it.
        app.filesJSON = "{}"
        app.version += 1
        app.updatedAt = .now
        Theme.Haptics.success()
        onRestore(restored)
        dismiss()
    }
}

/// Renders mini-app icon: SF Symbol if set, else emoji.
struct MiniAppIconView: View {
    var emoji: String
    var iconSymbol: String?
    var size: CGFloat = 40
    @Environment(\.colorScheme) private var colorScheme

    private var isSymbol: Bool { !(iconSymbol ?? "").isEmpty }
    private var seed: String { (iconSymbol ?? "") + emoji }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Theme.tileGradient(for: seed, deep: isSymbol, dark: colorScheme == .dark))
            .frame(width: size, height: size)
            .overlay {
                if isSymbol {
                    Image(systemName: iconSymbol!)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Text(emoji.isEmpty ? "✨" : emoji)
                        .font(.system(size: size * 0.56))
                }
            }
            .overlay(
                // The rim sits on the colored gradient tile, never on the
                // scheme background — white reads correctly in both schemes.
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            )
    }
}
