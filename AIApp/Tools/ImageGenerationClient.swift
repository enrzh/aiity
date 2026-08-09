import Foundation

/// Wire protocol a provider expects for image generation.
///
/// There are two in the wild, and picking the wrong one is a hard 404:
/// - `imagesEndpoint` — `POST {base}/images/generations`, the OpenAI shape that
///   OpenAI, the Gemini OpenAI-compat layer, xAI and most self-hosted gateways
///   implement.
/// - `chatCompletions` — the image comes back from `POST {base}/chat/completions`
///   with `modalities: ["image","text"]`. **OpenRouter serves no `/images` route
///   at all**, so this is the only way to generate an image there — and
///   OpenRouter is this app's default (and one-tap-login) provider, which is
///   why every generation on a fresh install used to fail.
enum ImageWire: String, Equatable {
    case imagesEndpoint
    case chatCompletions

    var path: String {
        switch self {
        case .imagesEndpoint: return "/images/generations"
        case .chatCompletions: return "/chat/completions"
        }
    }

    /// The other wire, tried once when the first one says "no such endpoint".
    var alternative: ImageWire {
        self == .imagesEndpoint ? .chatCompletions : .imagesEndpoint
    }
}

/// Everything about *asking* for an image: which wire, which size, which body.
enum ImageRequestBuilder {
    static let defaultSize = "1024x1024"

    /// Presets known to have no `/images/generations` route.
    static let chatCompletionsPresets: Set<String> = ["openrouter"]

    static func preferredWire(presetId: String, model: String) -> ImageWire {
        if chatCompletionsPresets.contains(presetId) { return .chatCompletions }
        // An OpenRouter-style namespaced id on a gateway that proxies OpenRouter
        // (`openai/gpt-image-1`, `google/gemini-2.5-flash-image`) is still an
        // /images candidate — gateways normalise it — so only the preset decides.
        return .imagesEndpoint
    }

    /// Sizes each model family actually accepts. Sending `1024x1536` to
    /// `dall-e-3` is a 400, and sending any `size` at all over the
    /// chat-completions wire is a 400 — both used to happen.
    static func sanitizedSize(_ requested: String?, model: String, wire: ImageWire) -> String? {
        guard wire == .imagesEndpoint else { return nil }
        let lower = model.lowercased()
        let asked = (requested ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let wellFormed = asked.range(of: "^[0-9]{2,4}x[0-9]{2,4}$", options: .regularExpression) != nil
            || asked == "auto"

        func pick(_ allowed: [String], fallback: String) -> String {
            guard wellFormed, !asked.isEmpty else { return fallback }
            if allowed.contains(asked) { return asked }
            // Keep the requested aspect ratio when the exact pixels are refused.
            let parts = asked.split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { return fallback }
            let wantsPortrait = parts[1] > parts[0]
            let wantsLandscape = parts[0] > parts[1]
            if wantsPortrait, let portrait = allowed.first(where: { aspect($0) == .portrait }) { return portrait }
            if wantsLandscape, let landscape = allowed.first(where: { aspect($0) == .landscape }) { return landscape }
            return fallback
        }

        if lower.contains("dall-e-3") || lower.contains("dall_e_3") {
            return pick(["1024x1024", "1024x1792", "1792x1024"], fallback: "1024x1024")
        }
        if lower.contains("dall-e-2") || lower.contains("dall_e_2") {
            // Only squares; the aspect-preserving branch would return nonsense.
            return ["256x256", "512x512", "1024x1024"].contains(asked) ? asked : "1024x1024"
        }
        // gpt-image-1 and the generic case.
        return pick(["1024x1024", "1024x1536", "1536x1024"], fallback: defaultSize)
    }

    private enum Aspect { case square, portrait, landscape }

    private static func aspect(_ size: String) -> Aspect {
        let parts = size.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return .square }
        if parts[1] > parts[0] { return .portrait }
        if parts[0] > parts[1] { return .landscape }
        return .square
    }

    static func body(wire: ImageWire, model: String, prompt: String, size: String?) -> [String: Any] {
        switch wire {
        case .imagesEndpoint:
            var body: [String: Any] = ["model": model, "prompt": prompt, "n": 1]
            // Note: gpt-image-1 rejects `response_format` (400) and always
            // returns b64_json; dall-e returns a url. So we don't send it and
            // accept both shapes on the way back.
            if let size, !size.isEmpty { body["size"] = size }
            return body
        case .chatCompletions:
            return [
                "model": model,
                "modalities": ["image", "text"],
                "stream": false,
                "messages": [["role": "user", "content": prompt]],
            ]
        }
    }
}

/// Why an image generation did not produce an image. The kind drives both the
/// wording the user gets and whether the model may try again.
struct ImageGenerationFailure: Equatable {
    enum Kind: Equatable {
        /// No such endpoint on this provider — worth retrying on the other wire.
        case unsupportedEndpoint
        /// The provider rejected a parameter we sent (`size`, `modalities`, …).
        case badParameter(String?)
        case auth
        case rateLimit
        case contentPolicy
        case emptyResult
        case undecodable
        case transport
        case other
    }

    var kind: Kind
    /// German, user-facing, says what to do next.
    var message: String

    /// Whether asking again could plausibly succeed. A misconfigured provider
    /// or a refused motif will fail identically every time, and the model used
    /// to burn the whole tool budget rediscovering that.
    var isRetryable: Bool {
        switch kind {
        case .rateLimit, .transport: return true
        default: return false
        }
    }
}

enum ImageParseResult: Equatable {
    case bytes(Data)
    case remote(URL)
    case failure(ImageGenerationFailure)
}

/// Pure response handling — every shape a provider has been seen to answer with.
/// Kept free of networking so all of it is unit-testable.
enum ImageResponseParser {

    /// Magic-byte check. Without it an expired/403 image URL that answers with
    /// an HTML error page got stored as a "PNG", and the chat showed a blank
    /// bubble while the model told the user the picture was ready.
    static func looksLikeImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 4 else { return false }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }            // PNG
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }                  // JPEG
        if bytes.starts(with: Array("GIF8".utf8)) { return true }                  // GIF
        if bytes.starts(with: Array("BM".utf8)) { return true }                    // BMP
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)),
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return true }              // WEBP
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) { return true }  // HEIC/AVIF
        if bytes.starts(with: Array("<svg".utf8)) { return true }                  // SVG
        return false
    }

    /// Decodes base64 that may be padded oddly, wrapped in newlines, or handed
    /// over as a full `data:image/png;base64,…` URI (gateways do all three).
    static func decodeBase64Image(_ raw: String) -> Data? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("data:") {
            guard let comma = value.firstIndex(of: ",") else { return nil }
            value = String(value[value.index(after: comma)...])
        }
        value = value.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        // URL-safe base64 (some gateways emit it) and missing padding.
        value = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if value.count % 4 != 0 {
            value += String(repeating: "=", count: 4 - value.count % 4)
        }
        return Data(base64Encoded: value, options: [.ignoreUnknownCharacters])
    }

    static func parse(status: Int, data: Data, model: String) -> ImageParseResult {
        let bodyText = String(decoding: data.prefix(2000), as: UTF8.self)
        let object = jsonObject(data)

        if status != 200 {
            return .failure(failure(status: status, body: bodyText, object: object, model: model))
        }
        // Some gateways answer 200 with an error envelope.
        if let object, object["error"] != nil, candidate(in: object) == nil {
            return .failure(failure(status: 200, body: bodyText, object: object, model: model))
        }
        guard let object else {
            return .failure(.init(
                kind: .undecodable,
                message: String(localized: "Bildgenerierung: Antwort des Anbieters war kein JSON (\(String(bodyText.prefix(160)))).")
            ))
        }
        guard let candidate = candidate(in: object) else {
            // Chat-completions wire that answered with words instead of a
            // picture (model can't do images, or politely refused). Quoting it
            // is far more useful than "unbekanntes Antwortformat".
            if let spoken = chatText(in: object), !spoken.isEmpty {
                let lower = spoken.lowercased()
                return .failure(.init(
                    kind: isContentPolicy(lower) ? .contentPolicy : .emptyResult,
                    message: String(localized: "Das Bild-Modell '\(model)' hat kein Bild erzeugt, sondern geantwortet: \(String(spoken.prefix(200)))")
                ))
            }
            if isEmptyResultEnvelope(object) {
                return .failure(.init(
                    kind: .emptyResult,
                    message: String(localized: "Der Anbieter hat kein Bild geliefert (leere Antwort). Meist kann das gewählte Bild-Modell '\(model)' keine Bilder erzeugen — unter Verbindungen → Bild ein echtes Bild-Modell wählen.")
                ))
            }
            return .failure(.init(
                kind: .undecodable,
                message: String(localized: "Bildgenerierung: unbekanntes Antwortformat des Anbieters (\(String(bodyText.prefix(160)))).")
            ))
        }
        switch candidate {
        case .base64(let raw):
            guard let decoded = decodeBase64Image(raw), !decoded.isEmpty else {
                return .failure(.init(
                    kind: .undecodable,
                    message: String(localized: "Bilddaten des Anbieters ließen sich nicht dekodieren (ungültiges Base64).")
                ))
            }
            guard looksLikeImage(decoded) else {
                return .failure(.init(
                    kind: .undecodable,
                    message: String(localized: "Der Anbieter hat Daten geliefert, die kein Bild sind.")
                ))
            }
            return .bytes(decoded)
        case .url(let string):
            guard let url = URL(string: string), url.scheme != nil else {
                return .failure(.init(
                    kind: .undecodable,
                    message: String(localized: "Der Anbieter hat eine unbrauchbare Bild-URL geliefert.")
                ))
            }
            return .remote(url)
        }
    }

    /// Validates bytes downloaded from a `url` response.
    static func validateRemote(status: Int, data: Data) -> ImageParseResult {
        guard status == 200 else {
            return .failure(.init(
                kind: .other,
                message: String(localized: "Das erzeugte Bild ließ sich nicht laden (HTTP \(status) beim Abruf der Bild-URL — der Link ist evtl. schon abgelaufen).")
            ))
        }
        guard looksLikeImage(data) else {
            return .failure(.init(
                kind: .undecodable,
                message: String(localized: "Unter der Bild-URL des Anbieters lag kein Bild.")
            ))
        }
        return .bytes(data)
    }

    // MARK: - Error mapping

    static func failure(status: Int, body: String, object: [String: Any]?, model: String) -> ImageGenerationFailure {
        let detail = providerMessage(body: body, object: object)
        let lower = (detail + " " + body).lowercased()

        if isContentPolicy(lower) {
            return .init(
                kind: .contentPolicy,
                message: String(localized: "Der Anbieter hat dieses Motiv abgelehnt (Inhaltsrichtlinie): \(String(detail.prefix(200))). Beschreibe das Bild harmloser oder ohne echte Personen/Marken.")
            )
        }
        if status == 401 || status == 403 || lower.contains("invalid api key") || lower.contains("unauthorized") {
            return .init(
                kind: .auth,
                message: String(localized: "Bildgenerierung: Anmeldung abgelehnt (HTTP \(status)). Unter Verbindungen → Bild einen gültigen API-Key für den Bild-Anbieter hinterlegen.")
            )
        }
        if status == 429 {
            return .init(
                kind: .rateLimit,
                message: String(localized: "Bildgenerierung: Rate-Limit oder Guthaben erschöpft (HTTP 429). Kurz warten oder Abrechnung beim Anbieter prüfen.")
            )
        }
        // A complaint about ONE parameter we sent is not "this endpoint does not
        // exist" — it is a request we can repeat without that parameter. Checked
        // first because such messages ("'size' is not supported with this
        // model") also contain the words the endpoint heuristic looks for.
        // `modalities` is the exception: that one means the wire is wrong.
        if status == 400 || status == 422,
           let param = offendingParameter(lower: lower, object: object), param != "modalities" {
            return .init(
                kind: .badParameter(param),
                message: String(localized: "Bildgenerierung abgelehnt (HTTP \(status), Modell '\(model)'): \(String(detail.prefix(200)))")
            )
        }
        if isUnsupportedEndpoint(status: status, lower: lower) {
            return .init(
                kind: .unsupportedEndpoint,
                message: String(localized: "Dieser Anbieter bietet keine Bildgenerierung für '\(model)' an (HTTP \(status)). Unter Verbindungen → Bild einen Anbieter mit Bild-Modell wählen.")
            )
        }
        if status == 400 || status == 422 {
            return .init(
                kind: .badParameter(nil),
                message: String(localized: "Bildgenerierung abgelehnt (HTTP \(status), Modell '\(model)'): \(String(detail.prefix(200)))")
            )
        }
        return .init(
            kind: .other,
            message: String(localized: "Bildgenerierung fehlgeschlagen (HTTP \(status), Modell '\(model)'): \(String(detail.prefix(200)))")
        )
    }

    static func isContentPolicy(_ lower: String) -> Bool {
        let needles = [
            "content_policy", "content policy", "safety system", "safety_system",
            "moderation", "content_filter", "content filter", "responsible ai",
            "prohibited_content", "violates", "not allowed by our", "nsfw",
            "sicherheitsrichtlinie", "inhaltsrichtlinie",
        ]
        return needles.contains { lower.contains($0) }
    }

    static func isUnsupportedEndpoint(status: Int, lower: String) -> Bool {
        if status == 404 || status == 405 || status == 501 { return true }
        guard status == 400 || status == 422 else { return false }
        let needles = [
            "no endpoints found", "not supported", "unsupported", "unknown endpoint",
            "does not support", "no such model", "invalid url", "unrecognized request",
            "modalities", "image generation is not",
        ]
        return needles.contains { lower.contains($0) }
    }

    /// Which parameter the provider is complaining about, so the caller can
    /// retry once without it instead of failing the whole generation. Prefers
    /// the machine-readable `param` field; the text scan is quoted-token only
    /// (a bare substring search matches half the alphabet).
    static func offendingParameter(lower: String, object: [String: Any]?) -> String? {
        if let error = object?["error"] as? [String: Any], let param = error["param"] as? String, !param.isEmpty {
            return param
        }
        if let param = object?["param"] as? String, !param.isEmpty { return param }
        for param in ["size", "response_format", "quality", "style", "modalities"]
        where lower.contains("'\(param)'") || lower.contains("\"\(param)\"") || lower.contains(" \(param) ") {
            return param
        }
        return nil
    }

    static func providerMessage(body: String, object: [String: Any]?) -> String {
        if let object {
            if let error = object["error"] as? [String: Any] {
                if let message = error["message"] as? String, !message.isEmpty { return message }
                if let message = error["msg"] as? String, !message.isEmpty { return message }
                if let code = error["code"] as? String, !code.isEmpty { return code }
            }
            if let error = object["error"] as? String, !error.isEmpty { return error }
            if let message = object["message"] as? String, !message.isEmpty { return message }
            if let detail = object["detail"] as? String, !detail.isEmpty { return detail }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Payload extraction

    enum Candidate: Equatable {
        case base64(String)
        case url(String)
    }

    private static let base64Keys = ["b64_json", "b64", "base64", "image_base64", "imageBytes", "image", "data"]
    private static let urlKeys = ["url", "image_url", "uri"]

    /// Finds the image payload in any of the shapes providers answer with:
    /// `data[0]`, `images[0]`, `artifacts[0]`, `output[0]`, the object itself,
    /// or an OpenRouter-style `choices[0].message.images[0].image_url.url`.
    static func candidate(in object: [String: Any]) -> Candidate? {
        // OpenAI images endpoint and friends.
        for key in ["data", "images", "artifacts", "output", "predictions"] {
            if let array = object[key] as? [[String: Any]], let first = array.first,
               let found = candidate(inLeaf: first) {
                return found
            }
            // `images: ["data:image/png;base64,…"]`
            if let array = object[key] as? [String], let first = array.first,
               let found = candidate(inString: first) {
                return found
            }
        }
        // Chat-completions wire (OpenRouter, Gemini image models on gateways).
        if let choices = object["choices"] as? [[String: Any]] {
            for choice in choices {
                guard let message = choice["message"] as? [String: Any] else { continue }
                if let images = message["images"] as? [[String: Any]] {
                    for image in images {
                        if let found = candidate(inLeaf: image) { return found }
                    }
                }
                if let images = message["images"] as? [String] {
                    for image in images {
                        if let found = candidate(inString: image) { return found }
                    }
                }
                // Multimodal content parts.
                if let parts = message["content"] as? [[String: Any]] {
                    for part in parts {
                        if let found = candidate(inLeaf: part) { return found }
                    }
                }
                // A bare data: URI as the whole content string.
                if let text = message["content"] as? String, text.hasPrefix("data:image") {
                    return .base64(text)
                }
            }
        }
        return candidate(inLeaf: object)
    }

    private static func candidate(inLeaf leaf: [String: Any]) -> Candidate? {
        for key in base64Keys {
            if let value = leaf[key] as? String, !value.isEmpty,
               let found = candidate(inString: value) {
                return found
            }
        }
        for key in urlKeys {
            if let value = leaf[key] as? String, !value.isEmpty,
               let found = candidate(inString: value) {
                return found
            }
            // `image_url: {"url": "…"}`
            if let nested = leaf[key] as? [String: Any] {
                if let value = nested["url"] as? String, let found = candidate(inString: value) {
                    return found
                }
            }
        }
        // `inline_data: {"data": "<b64>"}` (Gemini-shaped passthrough).
        for key in ["inline_data", "inlineData", "source"] {
            if let nested = leaf[key] as? [String: Any] {
                if let found = candidate(inLeaf: nested) { return found }
            }
        }
        return nil
    }

    private static func candidate(inString value: String) -> Candidate? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("data:") { return .base64(trimmed) }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return .url(trimmed) }
        // Long opaque string = base64 payload. Short ones are ids/prompts.
        if trimmed.count > 64, trimmed.range(of: "^[A-Za-z0-9+/=_\\-\\s]+$", options: .regularExpression) != nil {
            return .base64(trimmed)
        }
        return nil
    }

    /// Assistant text from a chat-completions answer, when there is one.
    static func chatText(in object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]] else { return nil }
        for choice in choices {
            guard let message = choice["message"] as? [String: Any] else { continue }
            let text = ProviderRequestSupport.text(fromContent: message["content"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// True for `{"data": []}` / `{"images": []}` — a well-formed answer that
    /// simply contains no image (the shape that produced the old, causeless
    /// "lieferte keine nutzbaren Bilddaten").
    static func isEmptyResultEnvelope(_ object: [String: Any]) -> Bool {
        for key in ["data", "images", "artifacts", "output", "choices"] {
            if let array = object[key] as? [Any], array.isEmpty { return true }
        }
        return false
    }
}
