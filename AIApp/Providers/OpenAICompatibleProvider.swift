import Foundation

/// Speaks the OpenAI chat-completions dialect — which also covers OpenRouter,
/// Ollama, LM Studio and most self-hosted gateways. Streaming tool-call
/// fragments arrive split across chunks and are assembled by index.
struct OpenAICompatibleProvider: LLMProvider {
    var baseURL: String
    var apiKey: String
    var model: String

    func streamChat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !apiKey.isEmpty {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": messages.map(Self.encodeMessage),
                    ]
                    if !tools.isEmpty {
                        body["tools"] = tools.map { [
                            "type": "function",
                            "function": [
                                "name": $0.name,
                                "description": $0.description,
                                "parameters": $0.parameters,
                            ],
                        ] }
                    }
                    request.httpBody = jsonData(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line; if errorBody.count > 600 { break } }
                        throw ProviderError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0, errorBody)
                    }

                    // Tool-call fragments accumulate here, keyed by index.
                    var pendingCalls: [Int: (id: String, name: String, args: String)] = [:]

                    for try await line in bytes.lines {
                        guard let payload = SSE.dataPayload(of: line) else { continue }
                        if payload == "[DONE]" { break }
                        guard let chunk = jsonObject(Data(payload.utf8)),
                              let choice = (chunk["choices"] as? [[String: Any]])?.first else { continue }
                        let delta = choice["delta"] as? [String: Any] ?? [:]
                        if let text = delta["content"] as? String, !text.isEmpty {
                            continuation.yield(.textDelta(text))
                        }
                        for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                            let index = fragment["index"] as? Int ?? 0
                            var call = pendingCalls[index] ?? (id: "", name: "", args: "")
                            if let id = fragment["id"] as? String { call.id = id }
                            if let function = fragment["function"] as? [String: Any] {
                                if let name = function["name"] as? String { call.name += name }
                                if let args = function["arguments"] as? String { call.args += args }
                            }
                            pendingCalls[index] = call
                        }
                    }

                    for index in pendingCalls.keys.sorted() {
                        let call = pendingCalls[index]!
                        continuation.yield(.toolCall(ToolCallData(
                            id: call.id.isEmpty ? "call_\(index)" : call.id,
                            name: call.name,
                            argumentsJSON: call.args.isEmpty ? "{}" : call.args
                        )))
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

    private static func encodeMessage(_ message: ChatMessage) -> [String: Any] {
        var encoded: [String: Any] = ["role": message.role.rawValue]
        switch message.role {
        case .tool:
            encoded["content"] = message.text
            encoded["tool_call_id"] = message.toolCallId ?? ""
        case .assistant where !message.toolCalls.isEmpty:
            encoded["content"] = message.text.isEmpty ? NSNull() : message.text
            encoded["tool_calls"] = message.toolCalls.map { [
                "id": $0.id,
                "type": "function",
                "function": ["name": $0.name, "arguments": $0.argumentsJSON],
            ] }
        default:
            encoded["content"] = message.text
        }
        return encoded
    }
}
