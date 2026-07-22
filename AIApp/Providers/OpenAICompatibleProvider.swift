import Foundation

/// Speaks the OpenAI chat-completions dialect — OpenRouter, Ollama, LM Studio,
/// Gemini OpenAI-compat, Groq, DeepSeek, xAI, etc.
///
/// Resilience:
/// - Retries **without tools** when the model rejects function calling (very common on Ollama / small models).
/// - Retries **non-streaming** if the server rejects `stream: true`.
/// - Parses `content` as string **or** array of parts; tolerates missing tool_call `index` (Ollama).
/// - OpenRouter Referer/Title headers; safe URL joining.
struct OpenAICompatibleProvider: LLMProvider {
    var baseURL: String
    var apiKey: String
    var model: String
    /// When true (Ollama/LM Studio/…), use lower temperature and shorter max tokens.
    var isLocalRuntime: Bool = false

    func streamChat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Never send tools to local runtimes even if caller passed any.
                    let effectiveTools = isLocalRuntime ? [] : tools
                    var attempt = 0
                    while true {
                        do {
                            try await Self.run(
                                baseURL: baseURL,
                                apiKey: apiKey,
                                model: model,
                                messages: messages,
                                tools: effectiveTools,
                                isLocalRuntime: isLocalRuntime,
                                allowToolRetry: !effectiveTools.isEmpty,
                                allowStreamRetry: true,
                                yield: { continuation.yield($0) }
                            )
                            continuation.finish()
                            return
                        } catch {
                            attempt += 1
                            // One automatic retry on flaky mobile networks.
                            if attempt < 2, NetworkErrorFriendly.isTransient(error), !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                continue
                            }
                            throw error
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        baseURL: String,
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        tools: [ToolSpec],
        isLocalRuntime: Bool,
        allowToolRetry: Bool,
        allowStreamRetry: Bool,
        yield: (ChatEvent) -> Void
    ) async throws {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.badResponse(0, "Kein Modell gewählt — unter Anbieter → Modelle laden auswählen.")
        }
        guard let url = ProviderRequestSupport.endpoint(
            base: baseURL,
            path: "/chat/completions"
        ) else {
            throw ProviderError.badResponse(0, "Ungültige Base-URL: \(baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        ProviderRequestSupport.applyOpenAICompatHeaders(to: &request, apiKey: apiKey, baseURL: baseURL)

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map(encodeMessage),
        ]
        if isLocalRuntime {
            body["temperature"] = LocalRuntimePolicy.temperature
            body["max_tokens"] = LocalRuntimePolicy.maxTokens
            // Ollama OpenAI-compat also honors top-level temperature; options help native.
            if baseURL.contains("11434") || baseURL.contains("ollama") {
                body["options"] = [
                    "temperature": LocalRuntimePolicy.temperature,
                    "num_predict": LocalRuntimePolicy.maxTokens,
                ]
            }
        } else {
            applyTokenLimit(&body, model: model)
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { [
                "type": "function",
                "function": [
                    "name": $0.name,
                    "description": $0.description,
                    "parameters": $0.parameters,
                ],
            ] as [String: Any] }
        }
        request.httpBody = jsonData(body)
        request.timeoutInterval = 600

        let (bytes, response) = try await ProviderHTTP.streaming.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 800 { break }
            }
            if allowToolRetry, ProviderRequestSupport.isToolUnsupportedError(status: status, body: errorBody) {
                try await run(
                    baseURL: baseURL, apiKey: apiKey, model: model,
                    messages: messages, tools: [],
                    isLocalRuntime: isLocalRuntime,
                    allowToolRetry: false, allowStreamRetry: allowStreamRetry,
                    yield: yield
                )
                return
            }
            if allowStreamRetry, ProviderRequestSupport.isStreamUnsupportedError(status: status, body: errorBody) {
                try await runNonStreaming(
                    baseURL: baseURL, apiKey: apiKey, model: model,
                    messages: messages, tools: tools,
                    isLocalRuntime: isLocalRuntime,
                    yield: yield
                )
                return
            }
            throw enhanceModelError(ProviderError.fromHTTP(status: status, body: errorBody), status: status, body: errorBody)
        }

        var pendingCalls: [Int: (id: String, name: String, args: String)] = [:]
        var nextIndex = 0
        var sawAnyDelta = false

        for try await line in bytes.lines {
            guard let payload = SSE.dataPayload(of: line) else { continue }
            if payload == "[DONE]" { break }
            guard let chunk = jsonObject(Data(payload.utf8)) else { continue }

            // Some gateways put error objects in the stream.
            if let err = chunk["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? String(describing: err)
                throw ProviderError.badResponse(status, msg)
            }

            guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { continue }
            let delta = choice["delta"] as? [String: Any] ?? [:]

            let text = ProviderRequestSupport.text(fromContent: delta["content"])
            if !text.isEmpty {
                sawAnyDelta = true
                yield(.textDelta(text))
            }
            // DeepSeek / some R1 ports stream reasoning separately — ignore for chat UI.

            let fragments = delta["tool_calls"] as? [[String: Any]] ?? []
            for (offset, fragment) in fragments.enumerated() {
                let index: Int
                if let i = fragment["index"] as? Int {
                    index = i
                } else if let i = fragment["index"] as? Double {
                    index = Int(i)
                } else {
                    // Ollama historically omitted index — assign stable order.
                    index = offset + nextIndex
                }
                nextIndex = max(nextIndex, index + 1)
                var call = pendingCalls[index] ?? (id: "", name: "", args: "")
                if let id = fragment["id"] as? String, !id.isEmpty { call.id = id }
                if let function = fragment["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { call.name += name }
                    if let args = function["arguments"] as? String { call.args += args }
                    // Some servers send arguments as object once.
                    if call.args.isEmpty, let obj = function["arguments"] as? [String: Any] {
                        call.args = String(decoding: jsonData(obj), as: UTF8.self)
                    }
                }
                // Non-delta full tool call shape
                if call.name.isEmpty, let name = fragment["name"] as? String {
                    call.name = name
                }
                pendingCalls[index] = call
                sawAnyDelta = true
            }

            // Non-streaming-shaped chunk mid-stream (message instead of delta)
            if delta.isEmpty, let message = choice["message"] as? [String: Any] {
                let content = ProviderRequestSupport.text(fromContent: message["content"])
                if !content.isEmpty {
                    sawAnyDelta = true
                    yield(.textDelta(content))
                }
            }
        }

        for index in pendingCalls.keys.sorted() {
            let call = pendingCalls[index]!
            guard !call.name.isEmpty else { continue }
            yield(.toolCall(ToolCallData(
                id: call.id.isEmpty ? "call_\(index)" : call.id,
                name: call.name,
                argumentsJSON: call.args.isEmpty ? "{}" : call.args
            )))
        }

        // Empty successful stream with no tools — often a silent model failure.
        if !sawAnyDelta && pendingCalls.isEmpty {
            // Fall back to non-stream once.
            if allowStreamRetry {
                try await runNonStreaming(
                    baseURL: baseURL, apiKey: apiKey, model: model,
                    messages: messages, tools: tools,
                    isLocalRuntime: isLocalRuntime,
                    yield: yield
                )
                return
            }
            throw ProviderError.badResponse(200, "Leere Antwort vom Modell — anderes Modell wählen oder Base-URL prüfen.")
        }

        yield(.done)
    }

    private static func runNonStreaming(
        baseURL: String,
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        tools: [ToolSpec],
        isLocalRuntime: Bool,
        yield: (ChatEvent) -> Void
    ) async throws {
        guard let url = ProviderRequestSupport.endpoint(base: baseURL, path: "/chat/completions") else {
            throw ProviderError.badResponse(0, "Ungültige Base-URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        ProviderRequestSupport.applyOpenAICompatHeaders(to: &request, apiKey: apiKey, baseURL: baseURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": messages.map(encodeMessage),
        ]
        if isLocalRuntime {
            body["temperature"] = LocalRuntimePolicy.temperature
            body["max_tokens"] = LocalRuntimePolicy.maxTokens
        } else {
            applyTokenLimit(&body, model: model)
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { [
                "type": "function",
                "function": [
                    "name": $0.name,
                    "description": $0.description,
                    "parameters": $0.parameters,
                ],
            ] as [String: Any] }
        }
        request.httpBody = jsonData(body)

        let (data, response) = try await ProviderHTTP.streaming.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let bodyText = String(decoding: data, as: UTF8.self)
            if ProviderRequestSupport.isToolUnsupportedError(status: status, body: bodyText), !tools.isEmpty {
                try await runNonStreaming(
                    baseURL: baseURL, apiKey: apiKey, model: model,
                    messages: messages, tools: [],
                    isLocalRuntime: isLocalRuntime,
                    yield: yield
                )
                return
            }
            throw enhanceModelError(ProviderError.fromHTTP(status: status, body: bodyText), status: status, body: bodyText)
        }
        guard let object = jsonObject(data),
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw ProviderError.badResponse(status, "Ungültige non-stream Antwort.")
        }
        let text = ProviderRequestSupport.text(fromContent: message["content"])
        if !text.isEmpty { yield(.textDelta(text)) }

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for (index, call) in toolCalls.enumerated() {
                let id = call["id"] as? String ?? "call_\(index)"
                let function = call["function"] as? [String: Any] ?? [:]
                let name = function["name"] as? String ?? ""
                var args = function["arguments"] as? String ?? ""
                if args.isEmpty, let obj = function["arguments"] as? [String: Any] {
                    args = String(decoding: jsonData(obj), as: UTF8.self)
                }
                guard !name.isEmpty else { continue }
                yield(.toolCall(ToolCallData(id: id, name: name, argumentsJSON: args.isEmpty ? "{}" : args)))
            }
        }
        yield(.done)
    }

    private static func enhanceModelError(_ error: ProviderError, status: Int, body: String) -> ProviderError {
        let lower = body.lowercased()
        let looksLikeMissingModel = status == 404
            || (lower.contains("model") && (lower.contains("not found") || lower.contains("does not exist") || lower.contains("invalid")))
        guard looksLikeMissingModel, case .badResponse(let s, let msg) = error else { return error }
        if msg.contains("Modelle laden") { return error }
        return .badResponse(s, msg + " — Einstellungen → Modelle laden und ein anderes Modell wählen.")
    }

    /// o-series / some newer OpenAI models reject `max_tokens` and want `max_completion_tokens`.
    /// Higher default so mini-app HTML is less often truncated mid-stream.
    static func applyTokenLimit(_ body: inout [String: Any], model: String, limit: Int = 12_288) {
        let id = model.lowercased()
        let usesCompletionTokens = id.contains("o1") || id.contains("o3") || id.contains("o4")
            || id.hasPrefix("gpt-5") || id.contains("gpt-4.1")
        if usesCompletionTokens {
            body["max_completion_tokens"] = limit
        } else {
            body["max_tokens"] = limit
        }
    }

    private static func encodeMessage(_ message: ChatMessage) -> [String: Any] {
        var encoded: [String: Any] = ["role": message.role.rawValue]
        switch message.role {
        case .tool:
            encoded["content"] = message.text
            encoded["tool_call_id"] = message.toolCallId ?? ""
            // Some servers also want the name.
            if let name = message.toolName, !name.isEmpty {
                encoded["name"] = name
            }
        case .assistant where !message.toolCalls.isEmpty:
            // Prefer empty string over null — stricter gateways reject null content.
            encoded["content"] = message.text
            encoded["tool_calls"] = message.toolCalls.map { [
                "id": $0.id,
                "type": "function",
                "function": ["name": $0.name, "arguments": $0.argumentsJSON],
            ] as [String: Any] }
        default:
            encoded["content"] = message.text
        }
        return encoded
    }
}
