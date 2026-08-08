import SwiftUI

/// Manage agent skills: toggle built-ins, install packages from GitHub / file.
struct SkillsView: View {
    @StateObject private var store = SkillStore()
    @State private var showingAdd = false
    @State private var showingImport = false
    @State private var upgrading = false

    var body: some View {
        List {
            let imported = store.skills.filter { !$0.builtin }
            let builtins = store.skills.filter(\.builtin)
            let active = store.skills.filter(\.enabled).count

            Section {
                Text(active == 0 ? "Keine Skills aktiv" : "\(active) aktiv")
                    .font(.subheadline)
                    .foregroundStyle(active == 0 ? .secondary : Color.accentColor)
            }

            if !imported.isEmpty {
                Section("Importiert") {
                    ForEach(imported) { skill in
                        skillRow(skill)
                    }
                }
            }

            Section("Integriert") {
                ForEach(builtins) { skill in
                    skillRow(skill)
                }
            }

            // Already-installed recommendations vanish from the lists (and
            // come back when the skill is deleted); a fully installed group
            // drops its whole section instead of showing an empty header.
            let openMiniApps = SkillRecommendations.remaining(
                SkillRecommendations.miniApps, installed: store.skills
            )
            let openAnthropic = SkillRecommendations.remaining(
                SkillRecommendations.anthropic, installed: store.skills
            )

            if !openMiniApps.isEmpty {
                Section("Empfohlen: Für Mini-Apps") {
                    ForEach(openMiniApps) { rec in
                        recommendationRow(rec)
                    }
                }
            }

            if !openAnthropic.isEmpty {
                Section("Empfohlen: Anthropic") {
                    ForEach(openAnthropic) { rec in
                        recommendationRow(rec)
                    }
                }
            }

            Section("Installieren") {
                Button {
                    showingImport = true
                } label: {
                    Label("GitHub / Datei", systemImage: "arrow.down.app")
                }
                .accessibilityIdentifier("skill-open-import")
                Button {
                    showingAdd = true
                } label: {
                    Label("Selbst schreiben", systemImage: "square.and.pencil")
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
        .navigationTitle("Skills")
        .sheet(isPresented: $showingAdd) {
            AddSkillSheet { name, instructions in
                store.add(name: name, instructions: instructions)
                Analytics.track("skill_authored")
            }
        }
        .sheet(isPresented: $showingImport) {
            ImportSkillModal(store: store)
        }
    }

    /// One tappable install row. Identifier stays `skill-rec-<installKey>` —
    /// the grouping above is purely presentational.
    private func recommendationRow(_ rec: SkillRecommendation) -> some View {
        Button {
            installRecommendation(rec)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: rec.systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                Text(rec.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
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

    private func skillRow(_ skill: AgentSkill) -> some View {
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
                    } else if skill.source != nil {
                        Text("Paket")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
