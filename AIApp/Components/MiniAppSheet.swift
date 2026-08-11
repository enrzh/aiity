import SwiftUI
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

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: ChatSession
    @Environment(\.openChatTab) private var openChatTab

    @StateObject private var browserState = MiniAppBrowserState()
    @State private var effectiveCapability: MiniAppCapability = .offline
    @State private var pendingDeclared: MiniAppCapability = .offline
    @State private var pendingHost: String?
    @State private var showConsent = false

    var body: some View {
        AppSheet(detents: [.large]) {
            runnerContent
        }
    }

    private var runnerContent: some View {
        NavigationStack {
            MiniAppRunnerView(
                appId: appId,
                html: html,
                capability: effectiveCapability,
                browserState: browserState
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
            .onAppear { resolveCapability() }
            .alert("Internetzugriff erlauben?", isPresented: $showConsent) {
                Button("Nur offline", role: .cancel) { effectiveCapability = .offline }
                Button("Erlauben") {
                    MiniAppConsent.allow(
                        appId: appId,
                        capability: pendingDeclared,
                        hosts: pendingHost.map { [$0] } ?? []
                    )
                    effectiveCapability = pendingDeclared
                }
            } message: {
                // Be explicit that access is two-way: these tiers can also SEND
                // whatever the app holds to a server, not just load data.
                let what = pendingDeclared == .browser
                    ? String(localized: "Webseiten öffnen und laden")
                    : String(localized: "Daten aus dem Internet laden")
                Text(String(localized: "Die App „\(name)“ möchte \(what) (\(pendingDeclared.label)). Sie kann dabei auch Daten an fremde Server senden. Nur erlauben, wenn du dieser App vertraust."))
            }
            .navigationTitle(name)
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
                        Image(systemName: "sparkles")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityLabel("Mit KI bearbeiten")
                    .accessibilityIdentifier("miniapp-ai-edit")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        MiniAppIconView(emoji: emoji, iconSymbol: iconSymbol, size: 22)
                        Text(name)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("miniapp-done")
                }
            }
        }
    }

    /// Offline apps run immediately; a network/browser app runs offline until
    /// the user consents (once per app).
    private func resolveCapability() {
        let declared = MiniAppCapability.from(html: html)
        let host = WebAppBuilder.openTarget(in: html).flatMap {
            NetworkTargetValidator.normalizeHost($0.host ?? "")
        }
        if MiniAppConsent.isAllowed(appId: appId, declared: declared),
           host == nil || MiniAppConsent.hosts(appId: appId).contains(host!) {
            effectiveCapability = declared
        } else {
            effectiveCapability = .offline
            pendingDeclared = declared
            pendingHost = host
            showConsent = true
        }
    }

    private func openAIEdit() {
        if let libraryId {
            session.startEditing(id: libraryId, name: name, html: html)
        } else {
            session.startEditingDraft(name: name, html: html, emoji: emoji)
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
                                HStack {
                                    Text(host)
                                    Spacer()
                                    Button(role: .destructive) {
                                        hosts.removeAll { $0 == host }
                                        _ = MiniAppConsent.revokeHost(appId: appId, host: host)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .accessibilityLabel("Host (host) widerrufen")
                                }
                            }
                        }
                    }

                    if !hosts.isEmpty {
                        Section {
                            Button("Alle Hosts widerrufen", role: .destructive) {
                                MiniAppConsent.revokeAllHosts(appId: appId)
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
                    Text("Nur öffentliche http(s)-Hosts ohne Pfad oder Port können erlaubt werden.")
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
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}
