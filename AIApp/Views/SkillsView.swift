import SwiftUI

/// Manage agent skills: toggle built-ins, install custom ones by pasting
/// instructions or from a URL to a markdown file.
struct SkillsView: View {
    @StateObject private var store = SkillStore()
    @State private var showingAdd = false
    @State private var importURL = ""
    @State private var importing = false

    var body: some View {
        NavigationStack {
            content
        }
    }

    private var content: some View {
        List {
            Section {
                ForEach(store.skills) { skill in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(skill.name)
                                if skill.builtin {
                                    Text("Integriert")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.15), in: Capsule())
                                }
                            }
                            Text(skill.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { skill.enabled },
                            set: { _ in store.toggle(skill) }
                        ))
                        .labelsHidden()
                    }
                    .swipeActions {
                        if !skill.builtin {
                            Button(role: .destructive) {
                                store.remove(skill)
                            } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                        }
                    }
                }
            } footer: {
                Text("Aktive Skills fließen in jede neue Unterhaltung ein und spezialisieren, wie der Agent Mini-Apps baut.")
            }

            Section("Skill installieren") {
                HStack {
                    TextField("URL zu einer Markdown-Datei", text: $importURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button {
                        importing = true
                        Task {
                            await store.install(from: importURL)
                            if store.errorMessage == nil { importURL = "" }
                            importing = false
                        }
                    } label: {
                        if importing { ProgressView() } else { Image(systemName: "arrow.down.circle") }
                    }
                    .disabled(importing || importURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button {
                    showingAdd = true
                } label: {
                    Label("Eigenen Skill schreiben", systemImage: "square.and.pencil")
                }
                if let error = store.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Agent-Skills")
        .sheet(isPresented: $showingAdd) {
            AddSkillSheet { name, instructions in
                store.add(name: name, instructions: instructions)
            }
        }
    }
}

private struct AddSkillSheet: View {
    let onSave: (String, String) -> Void
    @State private var name = ""
    @State private var instructions = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name des Skills", text: $name)
                Section("Anleitung für den Agenten") {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 220)
                        .font(.system(.footnote, design: .monospaced))
                }
            }
            .navigationTitle("Neuer Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        onSave(name, instructions)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || instructions.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
