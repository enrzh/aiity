import Foundation

/// Talks to OpenAI's Codex responses backend so a ChatGPT-subscription OAuth
/// token can drive inference. Ported from the sub2api gateway: the token only
/// works against chatgpt.com/backend-api/codex/responses, and only when the
/// caller presents as the official Codex CLI (user-agent / originator /
/// version) and sends the request in the Responses API shape (input array,
/// instructions, store:false, stream:true).
///
/// LIVE-VERIFICATION NOTE: the transform, headers, account-id extraction and
/// SSE parsing below are faithful to sub2api and unit-tested, but could not be
/// exercised against the private backend here (no test subscription). The one
/// open risk is whether the backend demands OpenAI's verbatim Codex system
/// prompt as `instructions`; we send the app's own system prompt. If rejected,
/// the exact prompt lives in sub2api at pkg/openai/instructions.txt.
struct OpenAICodexProvider: LLMProvider {
    var accessToken: String
    var accountId: String?
    var model: String

    private static let endpoint = "https://chatgpt.com/backend-api/codex/responses"
    private static let userAgent = "codex_cli_rs/0.144.1 (iOS; AIApp) AIApp"
    private static let codexVersion = "0.144.1"

    func streamChat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: Self.endpoint)!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                    request.setValue(Self.userAgent, forHTTPHeaderField: "user-agent")
                    request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
                    request.setValue(Self.codexVersion, forHTTPHeaderField: "version")
                    request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
                    request.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
                    if let accountId, !accountId.isEmpty {
                        request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
                    }
                    request.httpBody = jsonData(Self.buildBody(messages: messages, tools: tools, model: model))

                    request.timeoutInterval = 600
                    let (bytes, response) = try await ProviderHTTP.streaming.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line; if errorBody.count > 600 { break } }
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw ProviderError.fromHTTP(status: status, body: errorBody)
                    }

                    for try await line in bytes.lines {
                        guard let payload = SSE.dataPayload(of: line), payload != "[DONE]" else { continue }
                        for event in Self.parseEvent(payload) {
                            continuation.yield(event)
                        }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    if NetworkErrorFriendly.isTransient(error) {
                        continuation.finish(throwing: ProviderError.badResponse(
                            0, NetworkErrorFriendly.message(for: error)
                        ))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request shaping (Responses API)

    static func buildBody(messages: [ChatMessage], tools: [ToolSpec], model: String) -> [String: Any] {
        // The Codex endpoint rejects role:"system"; system guidance goes into
        // `instructions`, the rest becomes the typed `input` array.
        let instructions = messages.filter { $0.role == .system }
            .map(\.text).joined(separator: "\n\n")
        var input: [[String: Any]] = []
        for message in messages where message.role != .system {
            switch message.role {
            case .user:
                input.append(["type": "message", "role": "user",
                              "content": [["type": "input_text", "text": message.text]]])
            case .assistant:
                if !message.text.isEmpty {
                    input.append(["type": "message", "role": "assistant",
                                  "content": [["type": "output_text", "text": message.text]]])
                }
                for call in message.toolCalls {
                    input.append([
                        "type": "function_call",
                        "name": call.name,
                        "arguments": call.argumentsJSON,
                        "call_id": call.id,
                    ])
                }
            case .tool:
                input.append([
                    "type": "function_call_output",
                    "call_id": message.toolCallId ?? "",
                    "output": message.text,
                ])
            case .system:
                break
            }
        }

        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "store": false,
            "stream": true,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { spec -> [String: Any] in
                ["type": "function", "name": spec.name,
                 "description": spec.description, "parameters": spec.parameters]
            }
        }
        return body
    }

    // MARK: - Responses SSE parsing

    /// Maps one Responses-API event to zero or more ChatEvents. Text arrives as
    /// `response.output_text.delta`; tool calls as a completed
    /// `response.output_item.done` whose item is a function_call.
    static func parseEvent(_ payload: String) -> [ChatEvent] {
        guard let event = jsonObject(Data(payload.utf8)),
              let type = event["type"] as? String else { return [] }
        switch type {
        case "response.output_text.delta":
            if let delta = event["delta"] as? String, !delta.isEmpty {
                return [.textDelta(delta)]
            }
        case "response.output_item.done":
            if let item = event["item"] as? [String: Any], item["type"] as? String == "function_call" {
                let arguments = item["arguments"] as? String ?? "{}"
                return [.toolCall(ToolCallData(
                    id: item["call_id"] as? String ?? item["id"] as? String ?? "call_0",
                    name: item["name"] as? String ?? "",
                    argumentsJSON: arguments.isEmpty ? "{}" : arguments
                ))]
            }
        default:
            break
        }
        return []
    }
}
