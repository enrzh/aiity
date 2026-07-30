import Foundation

enum ChatRole: String, Codable {
    case system, user, assistant, tool
}

struct ToolCallData: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var argumentsJSON: String
}

/// One message in the conversation the agent loop maintains. Assistant
/// messages may carry tool calls; `tool` messages carry the result for a
/// specific `toolCallId`.
struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    var role: ChatRole
    var text: String
    var toolCalls: [ToolCallData] = []
    var toolCallId: String?
    var toolName: String?
    /// Generated media (image/video) attached to this message, by MediaStore id.
    var mediaIds: [String] = []
    /// In a group chat, which agent spoke. Nil = the user or the assistant.
    /// Stored by name/emoji rather than id so a message stays readable after
    /// its agent is deleted or renamed.
    var authorName: String?
    var authorEmoji: String?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        toolCalls: [ToolCallData] = [],
        toolCallId: String? = nil,
        toolName: String? = nil,
        mediaIds: [String] = [],
        authorName: String? = nil,
        authorEmoji: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.mediaIds = mediaIds
        self.authorName = authorName
        self.authorEmoji = authorEmoji
    }

    // Hand-written for the same reason as `ChatThread`: Swift's synthesized
    // decoder treats a defaulted property as REQUIRED, so every field added
    // here after the first release would make older stored messages — and with
    // them their whole thread, and with that the entire history array —
    // undecodable. Only `role` and `text` are genuinely mandatory.
    private enum CodingKeys: String, CodingKey {
        case id, role, text, toolCalls, toolCallId, toolName, mediaIds
        case authorName, authorEmoji
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try values.decode(ChatRole.self, forKey: .role)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        toolCalls = try values.decodeIfPresent([ToolCallData].self, forKey: .toolCalls) ?? []
        toolCallId = try values.decodeIfPresent(String.self, forKey: .toolCallId)
        toolName = try values.decodeIfPresent(String.self, forKey: .toolName)
        mediaIds = try values.decodeIfPresent([String].self, forKey: .mediaIds) ?? []
        authorName = try values.decodeIfPresent(String.self, forKey: .authorName)
        authorEmoji = try values.decodeIfPresent(String.self, forKey: .authorEmoji)
    }
}

struct ToolSpec {
    var name: String
    var description: String
    /// JSON-Schema for the arguments object.
    var parameters: [String: Any]
}

enum ChatEvent {
    case textDelta(String)
    case toolCall(ToolCallData)
    case done
}

protocol LLMProvider {
    func streamChat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ChatEvent, Error>
}

enum ProviderError: LocalizedError {
    case badResponse(Int, String)
    case missingKey

    var errorDescription: String? {
        switch self {
        case .badResponse(_, let body):
            // `body` is often already a friendly German string from ProviderRequestSupport.
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("API-Fehler") || trimmed.hasPrefix("Modell") || trimmed.hasPrefix("Auth")
                || trimmed.hasPrefix("Dieses Modell") || trimmed.hasPrefix("Kein Modell")
                || trimmed.hasPrefix("Ungültige") || trimmed.hasPrefix("Leere") {
                return String(trimmed.prefix(500))
            }
            return "API-Fehler: \(String(trimmed.prefix(400)))"
        case .missingKey:
            return "Kein API-Key hinterlegt — bitte in den Einstellungen eintragen."
        }
    }
}

enum SSE {
    /// Extracts the payload of an SSE `data:` line, nil for other lines.
    static func dataPayload(of line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }
}

func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func jsonData(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}
