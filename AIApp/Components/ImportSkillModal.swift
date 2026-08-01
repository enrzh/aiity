import SwiftUI
import UniformTypeIdentifiers

/// Modal to install a skill from GitHub-style text, URL, or local file (.md / .zip).
struct ImportSkillModal: View {
    @ObservedObject var store: SkillStore
    @Environment(\.dismiss) private var dismiss

    @State private var spec = ""
    @State private var importing = false
    @State private var showImporter = false
    @State private var localError: String?

    var body: some View {
        ModalChrome(
            title: String(localized: "Skill installieren"),
            confirmTitle: importing ? nil : String(localized: "Installieren"),
            confirmDisabled: spec.trimmingCharacters(in: .whitespaces).isEmpty || importing,
            onCancel: { dismiss() },
            onConfirm: importing ? nil : { Task { await installRemote() } }
        ) {
            Form {
                Section {
                    TextField("owner/repo, Pfad oder URL", text: $spec)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("skill-install-spec")
                        .onChange(of: spec) { _, newValue in
                            if PlainPasteboard.looksLikePasteboardArtifact(newValue) {
                                spec = PlainPasteboard.plainText() ?? ""
                            }
                        }
                    Button {
                        if let t = PlainPasteboard.plainText() { spec = t }
                    } label: {
                        Label("URL als Klartext einfügen", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("GitHub / URL")
                } footer: {
                    Text("z. B. owner/repo/skills/name@main — oder Empfohlene Skills (ohne Netz).")
                }

                Section("Lokale Datei") {
                    Button {
                        showImporter = true
                    } label: {
                        Label("SKILL.md oder .zip wählen", systemImage: "folder")
                    }
                    .accessibilityIdentifier("skill-file-import")
                }

                if importing {
                    Section { ProgressView("Installiere…") }
                }
                if let err = localError ?? store.errorMessage {
                    Section {
                        BannerView(message: err, kind: .error) {
                            localError = nil
                            store.errorMessage = nil
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, .utf8PlainText, .zip, UTType(filenameExtension: "md") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            Task { await handleFile(result) }
        }
    }

    private func installRemote() async {
        importing = true
        localError = nil
        await store.install(from: spec)
        importing = false
        if store.errorMessage == nil {
            Analytics.track("skill_installed", ["source": "remote"])
            dismiss()
        }
    }

    private func handleFile(_ result: Result<[URL], Error>) async {
        importing = true
        localError = nil
        defer { importing = false }
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let name = url.lastPathComponent.lowercased()
            if name.hasSuffix(".zip") {
                try store.installFromZipData(data, source: "file://\(url.lastPathComponent)")
            } else {
                let text = String(decoding: data, as: UTF8.self)
                _ = store.installPackage(markdown: text, source: "file://\(url.lastPathComponent)")
            }
            if store.errorMessage == nil {
                Analytics.track("skill_installed", ["source": "file"])
                dismiss()
            }
        } catch {
            localError = error.localizedDescription
        }
    }
}
