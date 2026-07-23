import Foundation

/// Shared request helpers so OpenAI-compat / Anthropic clients don't double
/// path segments or fail opaquely on tool-unsupported models.
enum ProviderRequestSupport {

    /// Join base + relative path without producing `/v1/v1/...`.
    static func endpoint(base: String, path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.hasPrefix("/") { p = "/" + p }

        // base already ends with /v1 and path starts with /v1/...
        if b.hasSuffix("/v1"), p.hasPrefix("/v1/") {
            p = String(p.dropFirst(3)) // keep leading /
        }
        // base ends with /v1 and path is /v1
        if b.hasSuffix("/v1"), p == "/v1" {
            return URL(string: b)
        }
        return URL(string: b + p)
    }

    /// Extract text from OpenAI-style `content` that may be a string or array of parts.
    static func text(fromContent content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { part -> String? in
                if let t = part["text"] as? String { return t }
                if let t = part["content"] as? String { return t }
                return nil
            }.joined()
        }
        return ""
    }

    /// True when the API rejected the request because of tools / function calling.
    static func isToolUnsupportedError(status: Int, body: String) -> Bool {
        guard status == 400 || status == 404 || status == 422 else { return false }
        let lower = body.lowercased()
        let needles = [
            "tool", "function call", "function_call", "tools is not supported",
            "does not support tools", "tool_choice", "functions are not supported",
            "not support function", "tool use", "tool_use", "parallel_tool",
            "unknown field.*tools", "additional properties.*tools",
        ]
        return needles.contains { lower.range(of: $0, options: .regularExpression) != nil }
            || (lower.contains("tools") && (lower.contains("support") || lower.contains("invalid") || lower.contains("unknown")))
    }

    /// True when streaming is the problem (retry non-stream).
    static func isStreamUnsupportedError(status: Int, body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("stream") && (
            lower.contains("not support") || lower.contains("unsupported")
            || lower.contains("invalid") || status == 400
        )
    }

    /// Human-friendly German error from status + body (JSON `error.message` if present).
    static func friendlyError(status: Int, body: String) -> String {
        var detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let obj = jsonObject(Data(detail.utf8)) {
            if let err = obj["error"] as? [String: Any] {
                if let msg = err["message"] as? String { detail = msg }
                else if let msg = err["msg"] as? String { detail = msg }
            } else if let msg = obj["message"] as? String {
                detail = msg
            }
        }
        detail = String(detail.prefix(400))
        if detail.isEmpty {
            if status == 0 {
                return "Keine Antwort vom Server — Netz oder Base-URL prüfen."
            }
            return "API-Fehler \(status) (keine Details)."
        }
        // Common model-id failures
        let lower = detail.lowercased()
        if status == 404 || lower.contains("model") && (lower.contains("not found") || lower.contains("does not exist") || lower.contains("invalid model")) {
            return "Modell nicht gefunden: \(detail) — unter Anbieter ein gültiges Modell wählen."
        }
        if status == 401 || status == 403 {
            return "Auth-Fehler \(status): \(detail) — API-Key oder Abo-Login erneuern (bei ChatGPT-Abo: erneut anmelden)."
        }
        if status == 429 {
            return "Rate-Limit / Kontingent erschöpft — kurz warten oder anderes Modell/Konto."
        }
        if isToolUnsupportedError(status: status, body: detail) {
            return "Dieses Modell unterstützt keine Tool-Calls. Die App versucht es ohne Tools erneut…"
        }
        if lower.contains("connection") && lower.contains("lost") {
            return "Verbindung unterbrochen — erneut senden."
        }
        return "API-Fehler \(status): \(detail)"
    }

    static func applyOpenAICompatHeaders(to request: inout URLRequest, apiKey: String, baseURL: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Long chat / mini-app streams (was 120s → frequent Zeitüberschreitung).
        request.timeoutInterval = 600
        if apiKey.hasPrefix(AuthStore.oauthMarker) {
            request.setValue("Bearer \(String(apiKey.dropFirst(AuthStore.oauthMarker.count)))", forHTTPHeaderField: "Authorization")
        } else if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // OpenRouter ranks apps that send these; harmless elsewhere.
        if baseURL.contains("openrouter.ai") {
            request.setValue("https://aiity.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("aiity", forHTTPHeaderField: "X-Title")
        }
        // Grok's CLI proxy only accepts a subscription token when the request
        // presents the grok-cli identity (values ported from the sub2api gateway).
        if baseURL.contains("grok.com"), apiKey.hasPrefix(AuthStore.oauthMarker) {
            request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
            request.setValue(GrokCLI.clientVersion, forHTTPHeaderField: "x-grok-client-version")
            request.setValue(GrokCLI.userAgent, forHTTPHeaderField: "User-Agent")
        }
    }
}

/// grok-cli client identity required by cli-chat-proxy.grok.com (from sub2api).
enum GrokCLI {
    static let clientVersion = "0.2.93"
    static let userAgent = "grok-pager/\(clientVersion) grok-shell/\(clientVersion) (macos; aarch64)"
}

extension ProviderError {
    /// Prefer parsed JSON message over raw body dump.
    static func fromHTTP(status: Int, body: String) -> ProviderError {
        .badResponse(status, ProviderRequestSupport.friendlyError(status: status, body: body))
    }
}
