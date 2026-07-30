import SwiftUI

/// Manage the worker agents the chat can delegate to. Each one carries its own
/// role and can run on a different provider/model than the chat itself.
struct AgentsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @StateObject private var store = AgentStore()
    @State private var editing: AgentDefinition?
    @State private var deleteCandidate: AgentDefinition?

    var body: some View {
        NavigationStack {
            Group {
                if store.agents.isEmpty {
                    AppEmptyState(
                        title: "Noch keine Agenten",
                        systemImage: "person.2",
                        message: "Lege Spezialisten an — Recherche, Code-Review, Übersetzung. Der Chat fragt sie von sich aus, wenn eine Aufgabe passt.",
                        actionTitle: "Agent anlegen",
                        action: { editing = AgentDefinition(name: "", role: "") }
                    )
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
                AgentEditSheet(agent: agent) { saved in
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

    private func agentRow(_ agent: AgentDefinition) -> some View {
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
                Toggle("", isOn: Binding(
                    get: { agent.enabled },
                    set: { _ in store.toggle(agent) }
                ))
                .labelsHidden()
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-row")
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
    var onSave: (AgentDefinition) -> Void

    @EnvironmentObject private var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        !agent.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !agent.role.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var chatProviderLabel: String {
        ProviderPreset.preset(for: settingsStore.settings.presetId).label
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (z. B. Rechercheur)", text: $agent.name)
                        .accessibilityIdentifier("agent-name")
                    TextField("Emoji", text: $agent.emoji)
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
                } header: {
                    Text("Aufgabe")
                } footer: {
                    Text("Wird zum System-Prompt des Agenten — und der Chat liest ihn, um zu entscheiden, wann er ihn fragt. Je konkreter, desto besser.")
                }

                Section {
                    Picker("Anbieter", selection: $agent.presetId) {
                        Text("Wie der Chat (\(chatProviderLabel))").tag("")
                        ForEach(ProviderPreset.catalog) { preset in
                            Text(preset.label).tag(preset.id)
                        }
                    }
                    TextField("Modell (leer = Standard)", text: $agent.model)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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
