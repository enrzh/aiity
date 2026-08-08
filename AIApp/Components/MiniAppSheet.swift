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

    @State private var effectiveCapability: MiniAppCapability = .offline
    @State private var pendingDeclared: MiniAppCapability = .offline
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
                capability: effectiveCapability
            )
            // The web view is non-opaque; keep a solid surface behind user
            // content so the sheet's glass background never bleeds into an
            // app that sets no background of its own.
            .background(Color(.systemBackground).ignoresSafeArea())
            .ignoresSafeArea(edges: .bottom)
            .onAppear { resolveCapability() }
            .alert("Internetzugriff erlauben?", isPresented: $showConsent) {
                Button("Nur offline", role: .cancel) { effectiveCapability = .offline }
                Button("Erlauben") {
                    MiniAppConsent.allow(appId: appId, capability: pendingDeclared)
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
        if MiniAppConsent.isAllowed(appId: appId, declared: declared) {
            effectiveCapability = declared
        } else {
            effectiveCapability = .offline
            pendingDeclared = declared
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
        dismiss()
        // Defer so sheet dismissal doesn't fight tab switch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            openChatTab()
            onEditWithAI?()
        }
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
