import Foundation

struct MCPToolDefinition: Codable, Equatable, Identifiable {
    var name: String
    var description: String
    var inputSchemaJSON: String
    var id: String { name }
}

struct MCPServerProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var url: String
    var enabled = true
    var tools: [MCPToolDefinition] = []
}

/// A hosted MCP service the user can configure in a browser. Recommendations
/// never contain a connection URL or credential: those belong to one user and
/// are only issued after that provider's setup flow.
struct MCPRecommendation: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let systemImage: String
    let setupURL: URL
    let googleServices: [String]

    func makeProfileDraft() -> MCPServerProfile {
        MCPServerProfile(name: name, url: "", enabled: false)
    }

    static let catalog: [MCPRecommendation] = [
        MCPRecommendation(
            id: "zapier",
            name: "Zapier MCP",
            summary: "Einfacher Einstieg für Google-Dienste und tausende weitere Apps.",
            systemImage: "bolt.fill",
            setupURL: URL(string: "https://mcp.zapier.com")!,
            googleServices: ["Google Drive", "Google Calendar", "Gmail"]
        ),
        MCPRecommendation(
            id: "pipedream",
            name: "Pipedream MCP",
            summary: "Viele APIs und Automationen, mit Remote-MCP für eigene Konten.",
            systemImage: "point.3.connected.trianglepath.dotted",
            setupURL: URL(string: "https://pipedream.com/docs/connect/mcp/users")!,
            googleServices: ["Google Drive", "Google Calendar", "Gmail"]
        ),
    ]
}

enum MCPStore {
    private static let key = "mcp.servers.v1"

    static func load() -> [MCPServerProfile] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MCPServerProfile].self, from: data)) ?? []
    }

    static func save(_ profiles: [MCPServerProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func token(for id: UUID) -> String { Keychain.get("mcp-token-\(id.uuidString)") }
    static func setToken(_ token: String, for id: UUID) { Keychain.set(token, for: "mcp-token-\(id.uuidString)") }
    static func removeToken(for id: UUID) { Keychain.set("", for: "mcp-token-\(id.uuidString)") }
}

enum MCPError: LocalizedError {
    case invalidURL, invalidResponse, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Ungültige MCP-Server-Adresse"
        case .invalidResponse: return "Der MCP-Server hat keine gültige Antwort geliefert."
        case .server(let message): return message
        }
    }
}

enum MCPClient {
    static func discover(profile: MCPServerProfile, token: String) async throws -> [MCPToolDefinition] {
        let session = try await request(profile: profile, token: token, method: "initialize", params: [
            "protocolVersion": "2025-03-26",
            "capabilities": [:],
            "clientInfo": ["name": "aiity", "version": "1"],
        ])
        try await notifyInitialized(profile: profile, token: token, sessionId: session.sessionId)
        let response = try await request(
            profile: profile, token: token, method: "tools/list", params: [:],
            sessionId: session.sessionId
        )
        guard let result = response.json["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { throw MCPError.invalidResponse }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let schema = tool["inputSchema"] as? [String: Any] ?? ["type": "object"]
            guard let data = try? JSONSerialization.data(withJSONObject: schema),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return MCPToolDefinition(name: name, description: tool["description"] as? String ?? name, inputSchemaJSON: json)
        }
    }

    static func call(profile: MCPServerProfile, token: String, tool: String, argumentsJSON: String) async throws -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let initialized = try await request(profile: profile, token: token, method: "initialize", params: [
            "protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "aiity", "version": "1"],
        ])
        try await notifyInitialized(profile: profile, token: token, sessionId: initialized.sessionId)
        let response = try await request(
            profile: profile, token: token, method: "tools/call",
            params: ["name": tool, "arguments": arguments], sessionId: initialized.sessionId
        )
        if let error = response.json["error"] as? [String: Any] {
            throw MCPError.server(error["message"] as? String ?? "MCP-Aufruf fehlgeschlagen")
        }
        guard let result = response.json["result"] as? [String: Any] else { throw MCPError.invalidResponse }
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? "MCP-Aufruf abgeschlossen." : text
    }

    private static func request(
        profile: MCPServerProfile, token: String, method: String, params: [String: Any], sessionId: String? = nil
    ) async throws -> (json: [String: Any], sessionId: String?) {
        guard let url = URL(string: profile.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw MCPError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw MCPError.server("MCP-Server nicht erreichbar.")
        }
        let payload: Data
        if let string = String(data: data, encoding: .utf8), string.hasPrefix("event:") || string.hasPrefix("data:") {
            let line = string.split(separator: "\n").first { $0.hasPrefix("data:") }
            payload = Data((line.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? "").utf8)
        } else { payload = data }
        guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw MCPError.invalidResponse }
        return (json, http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionId)
    }

    private static func notifyInitialized(profile: MCPServerProfile, token: String, sessionId: String?) async throws {
        guard let url = URL(string: profile.url) else { throw MCPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "notifications/initialized", "params": [:],
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw MCPError.server("MCP-Initialisierung fehlgeschlagen.")
        }
    }
}

struct MCPAgentTool: AgentTool {
    let profile: MCPServerProfile
    let definition: MCPToolDefinition

    var spec: ToolSpec {
        let parameters = ((try? JSONSerialization.jsonObject(with: Data(definition.inputSchemaJSON.utf8))) as? [String: Any]) ?? ["type": "object"]
        return ToolSpec(name: toolName, description: "\(profile.name): \(definition.description)", parameters: parameters)
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        do {
            return ToolRunResult(try await MCPClient.call(
                profile: profile, token: MCPStore.token(for: profile.id), tool: definition.name, argumentsJSON: argumentsJSON
            ))
        } catch {
            return ToolRunResult("Error: \(error.localizedDescription)", userNotice: error.localizedDescription)
        }
    }

    private var toolName: String {
        let clean = (profile.name + "_" + definition.name).lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "mcp_" + String(clean).prefix(58)
    }
}
