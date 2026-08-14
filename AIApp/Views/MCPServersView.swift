import SwiftUI

struct MCPServersView: View {
    @State private var profiles = MCPStore.load()
    @State private var draft: MCPServerProfile?
    @State private var draftRecommendation: MCPRecommendation?

    private let googleServices = [
        ("Gmail", "envelope"),
        ("Google Calendar", "calendar"),
        ("Google Drive", "externaldrive"),
    ]

    var body: some View {
        List {
            Section {
                Label("MCP verbindet aiity mit Werkzeugen und Daten externer Dienste.", systemImage: "shippingbox")
                Text("Du entscheidest beim Anbieter, welche Konten und Rechte freigegeben werden. Tool-Anfragen werden an diesen MCP-Anbieter gesendet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Was ist MCP?")
            }

            if !profiles.isEmpty {
                Section("Verbunden") {
                    ForEach(profiles) { profile in
                        NavigationLink {
                            MCPServerEditor(profile: profile, recommendation: recommendation(for: profile)) { save($0) }
                        } label: {
                            AppSettingsRow(
                                title: profile.name,
                                subtitle: profile.tools.isEmpty
                                    ? "Einrichtung nicht abgeschlossen"
                                    : "\(profile.tools.count) Werkzeuge · \(profile.enabled ? "Aktiv" : "Deaktiviert")",
                                systemImage: profile.enabled ? "shippingbox.fill" : "shippingbox"
                            )
                        }
                    }
                    .onDelete(perform: remove)
                }
            }

            Section("Empfohlen") {
                ForEach(MCPRecommendation.catalog) { recommendation in
                    Button { open(recommendation) } label: {
                        AppSettingsRow(
                            title: recommendation.name,
                            subtitle: recommendation.summary,
                            systemImage: recommendation.systemImage
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mcp-recommendation-\(recommendation.id)")
                }
            }

            Section("Google-Dienste") {
                ForEach(googleServices, id: \.0) { service, icon in
                    Menu {
                        ForEach(recommendations(for: service)) { recommendation in
                            Button { open(recommendation) } label: {
                                Label(recommendation.name, systemImage: recommendation.systemImage)
                            }
                        }
                    } label: {
                        AppSettingsRow(
                            title: service,
                            subtitle: "Über einen empfohlenen MCP-Anbieter verbinden",
                            systemImage: icon
                        ) {
                            // Same visual weight as the system disclosure chevron.
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section {
                Button {
                    draftRecommendation = nil
                    draft = MCPServerProfile(name: "MCP Server", url: "", enabled: false)
                } label: {
                    Label("Eigener Streamable-HTTP-MCP-Server", systemImage: "plus")
                }
            } header: {
                Text("Erweitert")
            } footer: {
                Text("Für einen bereits betriebenen Remote-MCP-Endpunkt. Desktop- oder stdio-MCP-Pakete laufen nicht direkt auf dem iPhone.")
            }
        }
        .navigationTitle("MCP Server")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $draft) { profile in
            NavigationStack {
                MCPServerEditor(profile: profile, recommendation: draftRecommendation) {
                    save($0)
                    draft = nil
                    draftRecommendation = nil
                }
            }
        }
    }

    private func open(_ recommendation: MCPRecommendation) {
        draftRecommendation = recommendation
        draft = recommendation.makeProfileDraft()
    }

    private func recommendations(for service: String) -> [MCPRecommendation] {
        MCPRecommendation.catalog.filter { $0.googleServices.contains(service) }
    }

    private func recommendation(for profile: MCPServerProfile) -> MCPRecommendation? {
        MCPRecommendation.catalog.first { $0.name == profile.name }
    }

    private func save(_ profile: MCPServerProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        MCPStore.save(profiles)
    }

    private func remove(_ offsets: IndexSet) {
        for index in offsets { MCPStore.removeToken(for: profiles[index].id) }
        profiles.remove(atOffsets: offsets)
        MCPStore.save(profiles)
    }
}

private struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: MCPServerProfile
    let recommendation: MCPRecommendation?
    @State private var token = ""
    @State private var testing = false
    @State private var result: String?
    @State private var testSucceeded = false
    let onSave: (MCPServerProfile) -> Void

    var body: some View {
        Form {
            if let recommendation {
                Section("Einrichtung") {
                    setupStep(1, "Konto bei \(recommendation.name) öffnen und die gewünschten Dienste verbinden.")
                    setupStep(2, "Einen MCP-Server erstellen. Falls ein Client gefragt wird, „Other“ oder tokenbasierte Einrichtung wählen.")
                    setupStep(3, "MCP-Endpunkt und Verbindungstoken kopieren und unten einsetzen.")
                    Link(destination: recommendation.setupURL) {
                        Label("\(recommendation.name) einrichten", systemImage: "safari")
                    }
                    Text("Unterstützt: \(recommendation.googleServices.joined(separator: ", ")) und weitere Dienste.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Voraussetzung") {
                    Text("Du brauchst die URL eines laufenden Remote-MCP-Servers mit Streamable HTTP. Ein Bearer Token ist optional, falls dein Server eines verlangt.")
                        .font(.footnote)
                }
            }

            Section("Verbindung") {
                TextField("https://…/mcp", text: $profile.url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("mcp-server-url")
                SecureField("Bearer Token (optional)", text: $token)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("mcp-server-token")
                if !profile.tools.isEmpty {
                    Toggle("Werkzeuge in Chats aktiv", isOn: $profile.enabled)
                }
            }

            Section {
                Button(action: testConnection) {
                    HStack {
                        Label("Testen und Werkzeuge laden", systemImage: "bolt.horizontal.circle")
                        Spacer()
                        // Stays mounted so the row never changes size while busy.
                        ProgressView()
                            .opacity(testing ? 1 : 0)
                    }
                    .animation(Theme.Motion.snappy, value: testing)
                }
                .disabled(testing || profile.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("mcp-test-connection")

                if let result {
                    Label {
                        Text(result)
                    } icon: {
                        TestResultIcon(ok: testSucceeded)
                    }
                    .font(.footnote)
                }
                ForEach(profile.tools) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.subheadline.weight(.medium))
                        Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            } header: {
                Text("Verbindung testen")
            } footer: {
                Text("Erst ein erfolgreicher Test aktiviert die gefundenen Werkzeuge.")
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { onSave(profile); dismiss() }
            }
        }
        .onAppear { token = MCPStore.token(for: profile.id) }
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space2) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)
                .background(.tint.opacity(0.12), in: Circle())
            Text(text).font(.footnote)
        }
    }

    private func testConnection() {
        testing = true
        testSucceeded = false
        withAnimation(Theme.Motion.snappy) { result = nil }
        profile.enabled = false
        Task { @MainActor in
            do {
                let discovered = try await MCPClient.discover(profile: profile, token: token)
                withAnimation(Theme.Motion.snappy) { profile.tools = discovered }
                guard !profile.tools.isEmpty else {
                    throw MCPError.server("Verbunden, aber der Server meldet keine Werkzeuge.")
                }
                withAnimation(Theme.Motion.snappy) {
                    profile.enabled = !profile.tools.isEmpty
                    testSucceeded = true
                    result = "Verbunden · \(profile.tools.count) Werkzeuge gefunden"
                }
                MCPStore.setToken(token, for: profile.id)
                onSave(profile)
            } catch {
                profile.enabled = false
                withAnimation(Theme.Motion.snappy) { result = error.localizedDescription }
            }
            testing = false
        }
    }
}

/// One-shot bounce on the success checkmark, mirroring the provider probe's
/// celebration moment. State + onAppear rather than a value-keyed effect:
/// the row is inserted already holding its final value, so a value change
/// would never be observed.
private struct TestResultIcon: View {
    let ok: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounced = false

    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? Color.green : Color.red)
            .symbolEffect(.bounce, options: .nonRepeating, value: bounced)
            .onAppear {
                // One-shot; Reduce Motion never triggers the bounce at all.
                if ok, !reduceMotion { bounced = true }
            }
    }
}
