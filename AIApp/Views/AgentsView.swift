import SwiftUI

/// Manage the worker agents the chat can delegate to. Each one carries its own
/// role and can run on a different provider/model than the chat itself.
struct AgentsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @ObservedObject private var store = AgentStore.shared
    @State private var editing: AgentDefinition?
    @State private var deleteCandidate: AgentDefinition?

    var body: some View {
        NavigationStack {
            Group {
                if store.agents.isEmpty {
                    List {
                        Section {
                            Text("Lege Spezialisten an — der Chat fragt sie von sich aus, wenn eine Aufgabe passt.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button {
                                editing = AgentDefinition(name: "", role: "")
                            } label: {
                                Label("Eigenen Agent anlegen", systemImage: "plus.circle")
                            }
                        } header: {
                            Text("Noch keine Agenten")
                        }

                        Section {
                            ForEach(AgentSuggestion.all) { template in
                                suggestionRow(template)
                            }
                        } header: {
                            Text("Vorschläge")
                        } footer: {
                            Text("Öffnet den Entwurf zum Anpassen. Das Modell wählst du selbst — jeder Vorschlag sagt dir, was dafür sinnvoll ist.")
                        }
                    }
                } else {
                    List {
                        Section {
                            ForEach(store.agents) { agent in
                                agentRow(agent)
                            }
                        } footer: {
                            Text("Der Chat entscheidet selbst, wen er fragt. Ausgeschaltete Agenten werden nie gefragt.")
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = AgentDefinition(name: "", role: "")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("add-agent")
                    .accessibilityLabel("Agent anlegen")
                }
            }
            .sheet(item: $editing) { agent in
                AgentEditSheet(
                    agent: agent,
                    existingNamesInit: Set(
                        store.agents
                            .filter { $0.id != agent.id }
                            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    )
                ) { saved in
                    if store.agents.contains(where: { $0.id == saved.id }) {
                        store.update(saved)
                    } else {
                        store.add(saved)
                    }
                }
                .environmentObject(settingsStore)
            }
            .confirmationDialog(
                "Agent löschen?",
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if !$0 { deleteCandidate = nil } }
                ),
                presenting: deleteCandidate
            ) { agent in
                Button("Löschen", role: .destructive) {
                    store.delete(agent)
                    deleteCandidate = nil
                }
                Button("Abbrechen", role: .cancel) { deleteCandidate = nil }
            } message: { agent in
                Text("„\(agent.name)“ wird entfernt.")
            }
        }
    }

    /// A suggestion opens the editor pre-filled rather than saving straight
    /// away — the user still names the model and can rewrite the role.
    private func suggestionRow(_ template: AgentSuggestion.Template) -> some View {
        Button {
            editing = AgentSuggestion.agent(from: template)
        } label: {
            HStack(spacing: 12) {
                Text(template.emoji).font(.title2).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(template.role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(template.modelHint)
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-suggestion")
    }

    private func agentRow(_ agent: AgentDefinition) -> some View {
        // The toggle is a SIBLING of the tap target, not nested inside it:
        // an interactive control inside a Button's label makes the whole row
        // one ambiguous accessibility element — bad for VoiceOver, and it made
        // the row unaddressable in UI tests.
        HStack(spacing: 12) {
            Button {
                editing = agent
            } label: {
                HStack(spacing: 12) {
                    Text(agent.emoji)
                        .font(.title2)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name.isEmpty ? "Ohne Namen" : agent.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(agent.enabled ? .primary : .secondary)
                        Text(agent.providerLabel(fallback: settingsStore.settings))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent-row")

            Toggle("", isOn: Binding(
                get: { agent.enabled },
                set: { _ in store.toggle(agent) }
            ))
            .labelsHidden()
            .accessibilityLabel("\(agent.name) aktiv")
        }
        .swipeActions {
            Button(role: .destructive) {
                deleteCandidate = agent
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }
}

/// Create or edit one agent: who it is, what it does, and which brain it uses.
struct AgentEditSheet: View {
    @State var agent: AgentDefinition
    var existingNamesInit: Set<String> = []
    var onSave: (AgentDefinition) -> Void

    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var writingRole = false
    @State private var roleError: String?

    /// Draft from the name when empty, sharpen what is there otherwise.
    private func writeRole() {
        writingRole = true
        roleError = nil
        Task {
            do {
                agent.role = try await AgentRoleWriter.write(
                    name: agent.name,
                    existing: agent.role,
                    settings: settingsStore.settings
                )
            } catch {
                roleError = error.localizedDescription
            }
            writingRole = false
        }
    }

    /// Existing names, so a duplicate can be refused rather than silently
    /// breaking group authorship and `ask_agent` routing (both key on the name).
    private var existingNames: Set<String> { existingNamesInit }

    private var trimmedName: String {
        agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameIsTaken: Bool {
        existingNames.contains(trimmedName.lowercased())
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
            && !agent.role.trimmingCharacters(in: .whitespaces).isEmpty
            && !nameIsTaken
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (z. B. Rechercheur)", text: $agent.name)
                        .accessibilityIdentifier("agent-name")
                    TextField("Emoji", text: $agent.emoji)
                    if nameIsTaken {
                        Text("Diesen Namen gibt es schon. Namen müssen eindeutig sein — der Chat spricht Agenten über den Namen an.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Agent")
                }

                Section {
                    TextField(
                        "Wofür ist dieser Agent zuständig?",
                        text: $agent.role,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    .accessibilityIdentifier("agent-role")

                    Button {
                        writeRole()
                    } label: {
                        if writingRole {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Schreibt…")
                            }
                        } else {
                            Label(
                                agent.role.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? "Mit KI beschreiben"
                                    : "Mit KI verbessern",
                                systemImage: "sparkles"
                            )
                        }
                    }
                    .disabled(writingRole)
                    .accessibilityIdentifier("agent-write-role")

                    if let roleError {
                        Text(roleError).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Aufgabe")
                } footer: {
                    Text("Wird zum System-Prompt des Agenten — und der Chat liest ihn, um zu entscheiden, wann er ihn fragt. Je konkreter, desto besser.")
                }

                Section {
                    // A pushed page, like the chat's provider button — an
                    // inline picker plus a free-text model field made you type
                    // an exact model id from memory.
                    NavigationLink {
                        AgentModelPicker(presetId: $agent.presetId, model: $agent.model)
                            .environmentObject(settingsStore)
                    } label: {
                        AppSettingsRow(
                            title: "Anbieter & Modell",
                            subtitle: agent.providerLabel(fallback: settingsStore.settings),
                            systemImage: "cpu"
                        )
                    }
                    .accessibilityIdentifier("agent-model")
                } header: {
                    Text("Modell")
                } footer: {
                    Text("Ein Agent darf ein ganz anderes Modell nutzen als der Chat — z. B. ein günstiges für Fleißarbeit und ein starkes fürs Gegenlesen.")
                }
            }
            .navigationTitle(agent.name.isEmpty ? "Neuer Agent" : agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        var trimmed = agent
                        trimmed.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        trimmed.role = agent.role.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.emoji.isEmpty { trimmed.emoji = "🤖" }
                        onSave(trimmed)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                    .accessibilityIdentifier("agent-save")
                }
            }
        }
    }
}
