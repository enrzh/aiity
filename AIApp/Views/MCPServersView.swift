import SwiftUI

struct MCPServersView: View {
    @State private var profiles = MCPStore.load()
    @State private var draft: MCPServerProfile?

    var body: some View {
        List {
            Section {
                ForEach(profiles) { profile in
                    NavigationLink {
                        MCPServerEditor(profile: profile) { save($0) }
                    } label: {
                        AppSettingsRow(
                            title: profile.name,
                            subtitle: profile.tools.isEmpty ? "Nicht getestet" : "\(profile.tools.count) Werkzeuge",
                            systemImage: profile.enabled ? "shippingbox.fill" : "shippingbox"
                        )
                    }
                }
                .onDelete(perform: remove)
            }

            Section("Hinzufügen") {
                Button { draft = MCPServerProfile(name: "MCP Server", url: "") } label: {
                    Label("Eigener MCP Server", systemImage: "plus")
                }
                ForEach(MCPServerProfile.templates) { template in
                    Button { draft = template } label: { Label(template.name, systemImage: "g.circle") }
                }
            }
        }
        .navigationTitle("MCP Server")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $draft) { profile in
            NavigationStack { MCPServerEditor(profile: profile) { save($0); draft = nil } }
        }
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
    @State private var token = ""
    @State private var testing = false
    @State private var result: String?
    let onSave: (MCPServerProfile) -> Void

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $profile.name)
                TextField("https://…/mcp", text: $profile.url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Bearer Token (optional)", text: $token)
                Toggle("Aktiv", isOn: $profile.enabled)
            }
            Section("Verbindung testen") {
                Button {
                    testing = true; result = nil
                    Task { @MainActor in
                        do {
                            profile.tools = try await MCPClient.discover(profile: profile, token: token)
                            result = "Verbunden · \(profile.tools.count) Werkzeuge gefunden"
                            MCPStore.setToken(token, for: profile.id)
                            onSave(profile)
                        } catch { result = error.localizedDescription }
                        testing = false
                    }
                } label: { testing ? AnyView(ProgressView()) : AnyView(Label("Testen und Werkzeuge laden", systemImage: "bolt.horizontal.circle")) }
                .disabled(testing || profile.url.isEmpty)
                if let result { Text(result).foregroundStyle(profile.tools.isEmpty ? Color.secondary : Color.green) }
                ForEach(profile.tools) { tool in
                    LabeledContent(tool.name, value: tool.description)
                }
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { onSave(profile); dismiss() } } }
        .onAppear { token = MCPStore.token(for: profile.id) }
    }
}
