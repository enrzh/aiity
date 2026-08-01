import SwiftUI

/// Modal to author a skill by name + markdown instructions.
struct AddSkillSheet: View {
    let onSave: (String, String) -> Void
    @State private var name = ""
    @State private var instructions = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ModalChrome(
            title: String(localized: "Neuer Skill"),
            confirmTitle: String(localized: "Sichern"),
            confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty
                || instructions.trimmingCharacters(in: .whitespaces).isEmpty,
            onCancel: { dismiss() },
            onConfirm: {
                onSave(name, instructions)
                dismiss()
            }
        ) {
            Form {
                TextField("Name des Skills", text: $name)
                Section("Anleitung für den Agenten") {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 220)
                        .font(.system(.footnote, design: .monospaced))
                }
            }
        }
    }
}
