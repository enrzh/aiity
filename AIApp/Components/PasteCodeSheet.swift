import SwiftUI
import UIKit

/// Collects OAuth authorization code / redirect URL after browser approval.
struct PasteCodeSheet: View {
    let providerLabel: String
    let busy: Bool
    var hint: String? = nil
    let onCancel: () -> Void
    let onSubmit: (String) -> Void

    @State private var code = ""
    @State private var pasteWarning: String?

    var body: some View {
        ModalChrome(
            title: "Anmeldung abschließen",
            confirmTitle: busy ? nil : "Verbinden",
            confirmDisabled: sanitizedCode.isEmpty,
            onCancel: onCancel,
            onConfirm: busy ? nil : { onSubmit(sanitizedCode) }
        ) {
            Form {
                Section {
                    Text(hint ?? defaultHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Code oder Weiterleitungs-URL") {
                    TextField("Code oder URL mit ?code=…", text: $code, axis: .vertical)
                        .lineLimit(1...6)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .textContentType(.none)
                        .accessibilityIdentifier("oauth-paste-field")
                        .onChange(of: code) { _, newValue in
                            // System paste can dump RTFD paths — strip immediately.
                            if PlainPasteboard.looksLikePasteboardArtifact(newValue) {
                                pasteWarning = "Zwischenablage enthielt formatierten Text (RTF). Bitte erneut als reinen Text kopieren oder „Einfügen“ tippen."
                                code = PlainPasteboard.plainText() ?? ""
                                return
                            }
                            if let clean = PlainPasteboard.sanitize(newValue), clean != newValue {
                                code = clean
                            }
                            pasteWarning = nil
                        }
                    Button {
                        pasteWarning = nil
                        if let clip = PlainPasteboard.plainText() {
                            code = clip
                        } else {
                            pasteWarning = "Kein nutzbarer Klartext in der Zwischenablage (kein RTF/RTFD-Pfad)."
                        }
                    } label: {
                        Label("Als Klartext einfügen", systemImage: "doc.on.clipboard")
                    }
                    if let pasteWarning {
                        Text(pasteWarning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if busy {
                    Section { ProgressView("Verbinde…") }
                }
            }
        }
    }

    private var sanitizedCode: String {
        PlainPasteboard.sanitize(code) ?? ""
    }

    private var defaultHint: String {
        "Im Browser hast du \(providerLabel) autorisiert. Kopiere den Code oder die URL aus der Adresszeile. Tipp: „Als Klartext einfügen“ — nicht manuell RTF aus Notes/Safari-Share."
    }
}
