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
                return String(localized: "Keine Antwort vom Server — Netz oder Base-URL prüfen.")
            }
            return "API-Fehler \(status) (keine Details)."
        }
        // Common model-id failures
        let lower = detail.lowercased()
        // Context-length overflow — turn the opaque 400 into actionable guidance
        // (common on small-window self-hosted/gateway models when editing a large
        // mini-app or after many tool results).
        if lower.contains("context length") || lower.contains("context_length")
            || lower.contains("maximum context") || lower.contains("context window")
            || lower.contains("reduce the length") || lower.contains("prompt is too long")
            || lower.contains("too many tokens") || (lower.contains("token") && lower.contains("exceed")) {
            return String(localized: "Kontext zu groß für dieses Modell — starte einen neuen Chat, sende kürzer, oder wähle ein Modell mit größerem Kontextfenster (Mini-App-Bearbeitung braucht viel Kontext).")
        }
        if status == 404 || lower.contains("model") && (lower.contains("not found") || lower.contains("does not exist") || lower.contains("invalid model")) {
            return String(localized: "Modell nicht gefunden: \(detail) — unter Anbieter ein gültiges Modell wählen.")
        }
        if status == 401 || status == 403 {
            return String(localized: "Auth-Fehler \(status): \(detail) — API-Key prüfen/erneuern. Bei eigenem Gateway (sub2api): stimmt der sk-…-Key mit dem Server überein?")
        }
        if status == 429 {
            // Billing exhaustion (insufficient_quota) is not a transient rate
            // limit — "kurz warten" would be wrong advice there.
            if lower.contains("insufficient_quota") || lower.contains("exceeded your current quota")
                || lower.contains("billing") || lower.contains("payment") || lower.contains("credit") {
                return String(localized: "Kontingent/Guthaben aufgebraucht — Abrechnung/Guthaben beim Anbieter prüfen (ein Abo deckt die API-Nutzung meist nicht ab; API-Key nutzen).")
            }
            return "Rate-Limit erreicht — kurz warten und erneut versuchen (ggf. anderes Modell/Konto)."
        }
        if isToolUnsupportedError(status: status, body: detail) {
            return String(localized: "Dieses Modell unterstützt keine Tool-Calls. Die App versucht es ohne Tools erneut…")
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
        // OpenRouter ranks apps that send these; harmless elsewhere. These
        // identify aiity as itself — they are not a claim to be another client.
        if baseURL.contains("openrouter.ai") {
            request.setValue("https://aiity.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("aiity", forHTTPHeaderField: "X-Title")
        }
    }
}

extension ProviderError {
    /// Prefer parsed JSON message over raw body dump.
    static func fromHTTP(status: Int, body: String) -> ProviderError {
        .badResponse(status, ProviderRequestSupport.friendlyError(status: status, body: body))
    }
}
