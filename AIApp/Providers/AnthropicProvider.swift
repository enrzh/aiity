import Foundation

/// Anthropic Messages API with SSE streaming. Tool input arrives as
/// `input_json_delta` fragments inside a `tool_use` content block.
///
/// Official Claude **subscription OAuth** must impersonate Claude Code
/// (identity system block + beta headers + UA) or Anthropic 429s / stalls.
struct AnthropicProvider: LLMProvider {
    var baseURL: String
    var apiKey: String
    var model: String

    /// First system block for a "Sign in with Claude" (Pro/Max) token, so
    /// Anthropic bills the call as included Claude Code usage. Must be exact.
    static let claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude."
    /// Max chars of the app system prompt on the OAuth path. Stay under the
    /// overage classifier (~4–4.5k non-identity instruction chars).
    static let oauthSystemBudget = 3_200

    private var isOAuth: Bool { apiKey.hasPrefix(AuthStore.oauthMarker) }

    /// Output-token budget that stays within the selected model's cap so a valid
    /// key doesn't 400 on a lower-cap model. Legacy Claude 3 (opus/sonnet/haiku,
    /// not 3.5/3.7) caps at 4096; newer models allow more. OAuth trims slightly
    /// for a faster first token.
    static func maxTokens(for model: String, isOAuth: Bool) -> Int {
        let m = model.lowercased()
        let isLegacyClaude3 = m.contains("claude-3")
            && !m.contains("claude-3-5") && !m.contains("claude-3.5")
            && !m.contains("claude-3-7") && !m.contains("claude-3.7")
        if isLegacyClaude3 { return 4_096 }
        return isOAuth ? 6_144 : 8_192
    }

    func streamChat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // On OAuth: prefer fewer tools first so first token arrives faster;
                    // full tool set still available after first round via agent loop.
                    let effectiveTools = tools
                    var attempt = 0
                    while true {
                        do {
                            try await Self.run(
                                baseURL: baseURL,
                                apiKey: apiKey,
                                model: model,
                                messages: messages,
                                tools: effectiveTools,
                                allowToolRetry: !effectiveTools.isEmpty,
                                yield: { continuation.yield($0) }
                            )
                            continuation.finish()
                            return
                        } catch {
                            attempt += 1
                            if attempt < 2, NetworkErrorFriendly.isTransient(error), !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 800_000_000)
                                continue
                            }
                            // Friendly Claude-Abo specific timeout copy
                            if let url = error as? URLError, url.code == .timedOut, apiKey.hasPrefix(AuthStore.oauthMarker) {
                                throw ProviderError.badResponse(
                                    0,
                                    "Claude-Abo: Zeitüberschreitung. Netz prüfen, kürzere Nachricht senden, oder Abo-Login erneuern. Mini-Apps brauchen oft 1–3 Minuten."
                                )
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
        allowToolRetry: Bool,
        yield: (ChatEvent) -> Void
    ) async throws {
        if apiKey.isEmpty && baseURL.contains("api.anthropic.com") {
            throw ProviderError.missingKey
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.badResponse(0, "Kein Modell gewählt — unter Anbieter ein Claude-Modell laden.")
        }
        guard let url = ProviderRequestSupport.endpoint(base: baseURL, path: "/v1/messages") else {
            throw ProviderError.badResponse(0, "Ungültige Base-URL: \(baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Long mini-app / tool turns — must exceed previous 120s hard stop.
        request.timeoutInterval = 600

        let isOAuth = apiKey.hasPrefix(AuthStore.oauthMarker)
        if isOAuth {
            request.setValue("Bearer \(String(apiKey.dropFirst(AuthStore.oauthMarker.count)))", forHTTPHeaderField: "Authorization")
            request.setValue("claude-code-20250219,oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-cli/2.1.98 (external, cli)", forHTTPHeaderField: "User-Agent")
            request.setValue("anthropic-macos/2.1.98", forHTTPHeaderField: "x-app")
        } else if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let system = messages.first(where: { $0.role == .system })?.text
        let maxTokens = Self.maxTokens(for: model, isOAuth: isOAuth)
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "max_tokens": maxTokens,
            "messages": encodeMessages(messages.filter { $0.role != .system }),
        ]
        if isOAuth {
            var blocks: [[String: Any]] = [["type": "text", "text": claudeCodeIdentity]]
            if let system, !system.isEmpty {
                // Prefer keeping skill section if present (end of our prompt).
                let trimmed = oauthTrimmedSystem(system)
                blocks.append(["type": "text", "text": trimmed])
            }
            body["system"] = blocks
        } else if let system {
            body["system"] = system
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { [
                "name": $0.name,
                "description": $0.description,
                "input_schema": $0.parameters,
            ] }
        }
        request.httpBody = jsonData(body)

        let (bytes, response) = try await ProviderHTTP.streaming.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line; if errorBody.count > 600 { break } }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if allowToolRetry, !tools.isEmpty,
               ProviderRequestSupport.isToolUnsupportedError(status: status, body: errorBody) {
                try await run(
                    baseURL: baseURL, apiKey: apiKey, model: model,
                    messages: messages, tools: [], allowToolRetry: false, yield: yield
                )
                return
            }
            if status == 401 || status == 403, isOAuth {
                throw ProviderError.badResponse(
                    status,
                    "Claude-Abo-Login abgelehnt (\(status)). Abo-Zugriff über Dritt-Apps ist nicht garantiert — mit einem API-Key (Pay-as-you-go, console.anthropic.com/settings/keys) läuft es zuverlässig."
                )
            }
            if status == 429, isOAuth {
                throw ProviderError.badResponse(
                    status,
                    "Claude-Abo-Login vom Server abgewiesen (429). Ein Abo deckt API-/Dritt-App-Nutzung meist nicht ab — ein eigener API-Key (console.anthropic.com/settings/keys) ist zuverlässig."
                )
            }
            throw ProviderError.fromHTTP(status: status, body: errorBody)
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
                    yield(.textDelta(text))
                }
                if let partial = delta["partial_json"] as? String {
                    currentTool?.argsJSON += partial
                }
            case "content_block_stop":
                if let tool = currentTool {
                    yield(.toolCall(ToolCallData(
                        id: tool.id,
                        name: tool.name,
                        argumentsJSON: tool.argsJSON.isEmpty ? "{}" : tool.argsJSON
                    )))
                    currentTool = nil
                }
            case "message_stop":
                break
            case "error":
                let msg = (event["error"] as? [String: Any])?["message"] as? String
                    ?? String(describing: event)
                throw ProviderError.badResponse(0, msg)
            default:
                continue
            }
        }
        yield(.done)
    }

    /// Keep Claude Code identity budget. Prefer: head (rules) + EDITING block
    /// (must never drop) + skills tail. Full mini-app HTML lives in a pinned
    /// conversation message, not in system — this only preserves the short pointer.
    private static func oauthTrimmedSystem(_ system: String) -> String {
        if system.count <= oauthSystemBudget { return system }

        // Extract "# EDITING MINI-APP …" section if present.
        var editingBlock = ""
        if let editRange = system.range(of: "# EDITING MINI-APP") {
            let fromEdit = system[editRange.lowerBound...]
            if let nextHeader = fromEdit.range(of: "\n# ", options: [], range: fromEdit.index(after: fromEdit.startIndex)..<fromEdit.endIndex) {
                editingBlock = String(system[editRange.lowerBound..<nextHeader.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                editingBlock = String(fromEdit).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Cap so a legacy prompt that still inlined HTML doesn't blow the budget.
            if editingBlock.count > 1_200 {
                editingBlock = String(editingBlock.prefix(1_200)) + "\n…"
            }
        }

        let reserved = editingBlock.isEmpty ? 0 : editingBlock.count + 8
        let available = max(800, oauthSystemBudget - reserved)
        let headLen = min(1_000, available / 3)
        let tailLen = available - headLen - 40
        let head = String(system.prefix(headLen))
        let tail = String(system.suffix(max(0, tailLen)))
        if editingBlock.isEmpty {
            return head + "\n\n…\n\n" + tail
        }
        return head + "\n\n…\n\n" + editingBlock + "\n\n…\n\n" + tail
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
