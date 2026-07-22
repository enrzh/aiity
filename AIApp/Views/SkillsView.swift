import SwiftUI

/// Manage agent skills: toggle built-ins, install packages from GitHub / file.
struct SkillsView: View {
    @StateObject private var store = SkillStore()
    @State private var showingAdd = false
    @State private var showingImport = false
    @State private var showUpgrade = false
    @State private var upgrading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let importedOn = store.skills.filter { !$0.builtin && $0.enabled }.count
                    let active = store.skills.filter(\.enabled).count
                    if active > 0 {
                        Label(
                            importedOn > 0
                                ? "\(importedOn) importiert + \(active - importedOn) integriert aktiv — Importierte haben Vorrang im Chat"
                                : "\(active) Skill\(active == 1 ? "" : "s") aktiv — greifen ab der nächsten Chat-Nachricht",
                            systemImage: "checkmark.seal.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                        .listRowBackground(Color.accentColor.opacity(0.08))
                    } else {
                        Label(
                            "Keine Skills aktiv — Schalter rechts einschalten",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }

                let imported = store.skills.filter { !$0.builtin }
                let builtins = store.skills.filter(\.builtin)

                if !imported.isEmpty {
                    Section {
                        ForEach(imported) { skill in
                            skillRow(skill)
                        }
                    } header: {
                        Text("Importiert")
                    } footer: {
                        Text("Importierte Skills haben Vorrang vor integrierten und landen zuerst im Prompt. Schalter muss „An“ sein.")
                    }
                }

                Section {
                    ForEach(builtins) { skill in
                        skillRow(skill)
                    }
                } header: {
                    Text("Integriert")
                } footer: {
                    Text("Nur eingeschaltete Skills. Nächste Chat-Nachricht genügt — kein Neustart.")
                }

                Section {
                    ForEach(SkillRecommendations.all) { rec in
                        Button {
                            installRecommendation(rec)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: rec.systemImage)
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rec.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(rec.blurb)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("In App enthalten · 1-Tipp-Install")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                                if upgrading {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .disabled(upgrading)
                        .accessibilityIdentifier("skill-rec-\(rec.id)")
                    }
                } header: {
                    Text("Empfohlen (in der App)")
                } footer: {
                    Text("Installiert die mitgelieferte SKILL.md (ohne Netz). Danach unter „Importiert“ mit Schalter „An“ — greift ab der nächsten Chat-Nachricht.")
                }

                Section("Installieren") {
                    Button {
                        if FreeTier.canInstallSkill(currentCustomCount: store.skills.filter { !$0.builtin }.count) {
                            showingImport = true
                        } else {
                            showUpgrade = true
                        }
                    } label: {
                        Label("Von GitHub / Datei…", systemImage: "arrow.down.app")
                    }
                    .accessibilityIdentifier("skill-open-import")
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Eigenen Skill schreiben", systemImage: "square.and.pencil")
                    }
                    if let error = store.errorMessage {
                        BannerView(message: error, kind: .error) {
                            store.errorMessage = nil
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    if let ok = store.lastInstallMessage {
                        BannerView(message: ok, kind: .success) {
                            store.lastInstallMessage = nil
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
            }
            .navigationTitle("Agent-Skills")
            .sheet(isPresented: $showingAdd) {
                AddSkillSheet { name, instructions in
                    store.add(name: name, instructions: instructions)
                    Analytics.track("skill_authored")
                }
            }
            .sheet(isPresented: $showingImport) {
                ImportSkillModal(store: store)
            }
            .sheet(isPresented: $showUpgrade) {
                UpgradeModal(
                    title: "Skill-Limit",
                    message: FreeTier.skillLimitMessage,
                    onDismiss: { showUpgrade = false }
                )
            }
        }
    }

    private func skillRow(_ skill: AgentSkill) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                    if skill.enabled {
                        Text("An")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    if skill.builtin {
                        Text("Integriert")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    } else if skill.source != nil {
                        Text("Paket")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                Text(skill.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
                    Text("Warnung: Anweisungen fast leer — Skill wirkt nicht")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { skill.enabled },
                set: { _ in store.toggle(skill) }
            ))
            .labelsHidden()
            .accessibilityIdentifier("skill-toggle-\(skill.name)")
        }
        .swipeActions {
            if !skill.builtin {
                Button(role: .destructive) {
                    store.remove(skill)
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            }
            if skill.source != nil {
                Button {
                    upgrading = true
                    Task {
                        await store.updateFromSource(skill)
                        upgrading = false
                    }
                } label: {
                    Label("Update", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
        }
    }

    private func installRecommendation(_ rec: SkillRecommendation) {
        if !FreeTier.canInstallSkill(currentCustomCount: store.skills.filter { !$0.builtin }.count) {
            showUpgrade = true
            return
        }
        upgrading = true
        store.errorMessage = nil
        store.lastInstallMessage = nil
        Task {
            // Prefer bundled package (offline, reliable).
            await store.install(from: rec.installKey)
            if store.errorMessage != nil, let remote = rec.remoteSource {
                await store.install(from: remote)
            }
            upgrading = false
            if store.errorMessage == nil {
                Analytics.track("skill_installed", ["source": "recommendation", "key": rec.installKey])
            }
        }
    }
}
