import Foundation

/// Anthropic Messages API with SSE streaming. Tool input arrives as
/// `input_json_delta` fragments inside a `tool_use` content block.
struct AnthropicProvider: LLMProvider {
    var baseURL: String
    var apiKey: String
    var model: String

    func streamChat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Self-hosted Anthropic-dialect servers may run keyless;
                    // only the hosted API clearly requires one.
                    if apiKey.isEmpty && baseURL.contains("api.anthropic.com") {
                        throw ProviderError.missingKey
                    }
                    var request = URLRequest(url: URL(string: "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/v1/messages")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if apiKey.hasPrefix(AuthStore.oauthMarker) {
                        // "Sign in with Claude" bearer token instead of a key.
                        request.setValue("Bearer \(String(apiKey.dropFirst(AuthStore.oauthMarker.count)))", forHTTPHeaderField: "Authorization")
                        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                    } else {
                        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    }
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    let system = messages.first(where: { $0.role == .system })?.text
                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "max_tokens": 8192,
                        "messages": Self.encodeMessages(messages.filter { $0.role != .system }),
                    ]
                    if let system { body["system"] = system }
                    if !tools.isEmpty {
                        body["tools"] = tools.map { [
                            "name": $0.name,
                            "description": $0.description,
                            "input_schema": $0.parameters,
                        ] }
                    }
                    request.httpBody = jsonData(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line; if errorBody.count > 600 { break } }
                        throw ProviderError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0, errorBody)
                    }

                    var currentTool: (id: String, name: String, argsJSON: String)?

                    for try await line in bytes.lines {
                        guard let payload = SSE.dataPayload(of: line),
                              let event = jsonObject(Data(payload.utf8)),
                              let type = event["type"] as? String else { continue }
                        switch type {
                        case "content_block_start":
                            if let block = event["content_block"] as? [String: Any],
                               block["type"] as? String == "tool_use" {
                                currentTool = (
                                    id: block["id"] as? String ?? UUID().uuidString,
                                    name: block["name"] as? String ?? "",
                                    argsJSON: ""
                                )
                            }
                        case "content_block_delta":
                            let delta = event["delta"] as? [String: Any] ?? [:]
                            if let text = delta["text"] as? String {
                                continuation.yield(.textDelta(text))
                            }
                            if let partial = delta["partial_json"] as? String {
                                currentTool?.argsJSON += partial
                            }
                        case "content_block_stop":
                            if let tool = currentTool {
                                continuation.yield(.toolCall(ToolCallData(
                                    id: tool.id,
                                    name: tool.name,
                                    argumentsJSON: tool.argsJSON.isEmpty ? "{}" : tool.argsJSON
                                )))
                                currentTool = nil
                            }
                        case "message_stop":
                            break
                        default:
                            continue
                        }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Anthropic has no `tool` role: tool results are user messages with
    /// `tool_result` blocks, assistant tool calls are `tool_use` blocks.
    private static func encodeMessages(_ messages: [ChatMessage]) -> [[String: Any]] {
        var encoded: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .tool:
                let block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": message.toolCallId ?? "",
                    "content": message.text,
                ]
                if var last = encoded.last, last["role"] as? String == "user",
                   var content = last["content"] as? [[String: Any]] {
                    content.append(block)
                    last["content"] = content
                    encoded[encoded.count - 1] = last
                } else {
                    encoded.append(["role": "user", "content": [block]])
                }
            case .assistant where !message.toolCalls.isEmpty:
                var content: [[String: Any]] = []
                if !message.text.isEmpty {
                    content.append(["type": "text", "text": message.text])
                }
                for call in message.toolCalls {
                    let input = jsonObject(Data(call.argumentsJSON.utf8)) ?? [:]
                    content.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": input,
                    ])
                }
                encoded.append(["role": "assistant", "content": content])
            default:
                encoded.append(["role": message.role.rawValue, "content": message.text])
            }
        }
        return encoded
    }
}
