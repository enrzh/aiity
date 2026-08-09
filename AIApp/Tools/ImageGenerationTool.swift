import Foundation

/// Generates an image on the **image** modality slot (its own provider+model,
/// independent of the chat provider) and stores the result so it survives a
/// restart alongside the conversation.
///
/// Two wires exist (`ImageWire`): the OpenAI `/images/generations` endpoint and
/// the chat-completions `modalities` shape OpenRouter requires. The preferred
/// one is chosen per provider, and a "no such endpoint" answer falls back to
/// the other one exactly once — a gateway that proxies a different upstream
/// than its preset suggests should still work.
struct ImageGenerationTool: AgentTool {
    var route: MediaRoute
    /// Per-turn failure budget. `ToolRegistry.makeTools` builds a fresh tool for
    /// every turn, so this counts failures within one turn only. A provider
    /// that is misconfigured (or a motif that was refused) fails identically
    /// every time; without this the model spent its whole tool budget
    /// rediscovering that, five HTTP round trips at a time.
    final class Attempts {
        var failures = 0
    }
    var attempts = Attempts()
    /// Injected in tests; production always uses the shared session.
    var session: URLSession = .shared

    static let maxFailuresPerTurn = 2

    var spec: ToolSpec {
        ToolSpec(
            name: "generate_image",
            description: "Generate an image from a text prompt and show it to the user. Use when the user asks for a picture, illustration, logo, artwork, etc.",
            parameters: [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "Detailed description of the image to generate"],
                    "size": ["type": "string", "description": "Optional. One of 1024x1024, 1024x1536, 1536x1024. Default 1024x1024."],
                ],
                "required": ["prompt"],
            ]
        )
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        let args = toolArguments(argumentsJSON)
        let prompt = (args["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return ToolRunResult("Error: empty prompt") }

        if attempts.failures >= Self.maxFailuresPerTurn {
            return Self.failed(String(localized: "Bildgenerierung ist in diesem Chat nicht möglich (mehrfach fehlgeschlagen)."))
        }

        let base = route.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            attempts.failures = Self.maxFailuresPerTurn
            return Self.failed(String(localized: "Kein Bild-Anbieter eingerichtet — unter Verbindungen → Bild einen Anbieter und ein Bild-Modell wählen."))
        }

        var wire = ImageRequestBuilder.preferredWire(presetId: route.presetId, model: route.model)
        var size = ImageRequestBuilder.sanitizedSize(args["size"] as? String, model: route.model, wire: wire)
        var triedAlternativeWire = false
        var droppedParameter = false

        while true {
            let outcome = await perform(wire: wire, prompt: prompt, size: size, base: base)
            switch outcome {
            case .bytes(let data):
                guard let mediaId = MediaStore.saveImage(pngData: data) else {
                    attempts.failures += 1
                    return Self.failed(String(localized: "Das Bild konnte nicht gespeichert werden (kein Speicherplatz?)."))
                }
                return ToolRunResult(String(localized: "Bild erstellt und dem Nutzer angezeigt."), mediaIds: [mediaId])

            case .remote(let url):
                let fetched = await download(url)
                if case .bytes(let data) = fetched, let mediaId = MediaStore.saveImage(pngData: data) {
                    return ToolRunResult(String(localized: "Bild erstellt und dem Nutzer angezeigt."), mediaIds: [mediaId])
                }
                attempts.failures += 1
                if case .failure(let failure) = fetched {
                    return Self.failed(failure.message, retryable: failure.isRetryable)
                }
                return Self.failed(String(localized: "Das erzeugte Bild ließ sich nicht laden."))

            case .failure(let failure):
                // One retry on the OTHER wire when the provider says it has no
                // such endpoint — this is what makes OpenRouter (and gateways
                // that proxy it) work at all.
                if failure.kind == .unsupportedEndpoint, !triedAlternativeWire {
                    triedAlternativeWire = true
                    wire = wire.alternative
                    size = ImageRequestBuilder.sanitizedSize(args["size"] as? String, model: route.model, wire: wire)
                    continue
                }
                // One retry without the parameter the provider objected to.
                if case .badParameter(let param) = failure.kind, param == "size", size != nil, !droppedParameter {
                    droppedParameter = true
                    size = nil
                    continue
                }
                attempts.failures += 1
                return Self.failed(failure.message, retryable: failure.isRetryable)
            }
        }
    }

    // MARK: - Networking

    private func perform(wire: ImageWire, prompt: String, size: String?, base: String) async -> ImageParseResult {
        guard let url = ProviderRequestSupport.endpoint(base: base, path: wire.path) else {
            return .failure(.init(
                kind: .other,
                message: String(localized: "Die Adresse des Bild-Anbieters ist ungültig: \(base)")
            ))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = bearerToken(from: route.apiKey)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if base.contains("openrouter.ai") {
            request.setValue("https://aiity.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("aiity", forHTTPHeaderField: "X-Title")
        }
        request.timeoutInterval = 180
        request.httpBody = jsonData(ImageRequestBuilder.body(
            wire: wire, model: route.model, prompt: prompt, size: size
        ))

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return ImageResponseParser.parse(status: status, data: data, model: route.model)
        } catch {
            return .failure(.init(
                kind: .transport,
                message: String(localized: "Bildgenerierung fehlgeschlagen: \(NetworkErrorFriendly.message(for: error))")
            ))
        }
    }

    private func download(_ url: URL) async -> ImageParseResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            return ImageResponseParser.validateRemote(status: status, data: data)
        } catch {
            return .failure(.init(
                kind: .transport,
                message: String(localized: "Das erzeugte Bild ließ sich nicht laden: \(NetworkErrorFriendly.message(for: error))")
            ))
        }
    }

    // MARK: - What the model is told

    /// The tool result is the model's only view of what happened, and it is
    /// what the model paraphrases to the user. So it carries the German cause
    /// AND an explicit instruction not to keep retrying a hard failure.
    static func failed(_ message: String, retryable: Bool = false) -> ToolRunResult {
        ToolRunResult(modelInstruction(message, retryable: retryable), userNotice: message)
    }

    static func modelInstruction(_ message: String, retryable: Bool = false) -> String {
        if retryable {
            return message + " " + String(localized: "Sag dem Nutzer genau das. Höchstens ein weiterer Versuch.")
        }
        return message + " " + String(localized: "Sag dem Nutzer genau das, in deiner Antwort, und rufe generate_image in diesem Zug nicht erneut auf.")
    }
}
