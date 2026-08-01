import SwiftUI
import UIKit

/// Report a model answer. Shows the exact text that will be sent before it is
/// sent — the app promises nothing leaves the device unless the user sends it,
/// and a reporting flow that hid its payload would quietly break that.
struct ReportContentSheet: View {
    let message: ChatMessage
    let provider: String
    let model: String
    var onDismiss: () -> Void

    @State private var reason: ContentReport.Reason = .hateful
    @State private var note = ""
    @State private var copied = false
    @FocusState private var noteFocused: Bool

    private var reportBody: String {
        ContentReport.body(
            message: message,
            reason: reason,
            note: note,
            provider: provider,
            model: model,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—",
            systemVersion: UIDevice.current.systemVersion
        )
    }

    var body: some View {
        ModalChrome(title: String(localized: "Inhalt melden"), onCancel: onDismiss) {
            Form {
                Section {
                    Picker("Grund", selection: $reason) {
                        ForEach(ContentReport.Reason.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("report-reason")
                } header: {
                    Text("Was stimmt nicht?")
                }

                Section {
                    TextField("Optional: was ist passiert?", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($noteFocused)
                        .accessibilityIdentifier("report-note")
                }

                Section {
                    Text(reportBody)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Das wird gesendet")
                } footer: {
                    Text(String(localized: "Nur diese eine Nachricht — nicht die Unterhaltung, nicht deine Schlüssel. Es geht an \(ContentReport.contactAddress); es gibt keinen aiity-Server, der das automatisch entgegennimmt."))
                }

                Section {
                    Button {
                        send()
                    } label: {
                        Label("Per E-Mail melden", systemImage: "envelope")
                    }
                    .accessibilityIdentifier("report-send")

                    Button {
                        UIPasteboard.general.string = reportBody
                        copied = true
                    } label: {
                        Label(copied ? "Kopiert" : "Meldung kopieren",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("report-copy")
                }
            }
        }
        .presentationDetents([.large])
    }

    private func send() {
        guard let url = ContentReport.mailURL(
            subject: ContentReport.subject(for: reason),
            body: reportBody
        ) else { return }
        // No mail account configured is a real case; fall back to the
        // clipboard rather than doing nothing visible.
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
            onDismiss()
        } else {
            UIPasteboard.general.string = reportBody
            copied = true
        }
    }
}
