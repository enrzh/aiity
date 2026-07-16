import Foundation

/// Generates an image via the provider's OpenAI-compatible images endpoint
/// (`{base}/images/generations`) — works with OpenAI, Gemini-compat, Grok,
/// sub2api and other gateways. The PNG is stored and shown inline in the chat.
struct ImageGenerationTool: AgentTool {
    var settings: ProviderSettings
    var apiKey: String

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
        let size = args["size"] as? String ?? "1024x1024"

        let base = settings.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: "\(base)/images/generations") else {
            return ToolRunResult("Error: no image endpoint configured for this provider")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = bearerToken(from: apiKey)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 120
        // Note: gpt-image-1 rejects `response_format` (400) and always returns
        // b64_json; dall-e returns a url. So we don't send it and accept both.
        request.httpBody = jsonData([
            "model": settings.imageModel,
            "prompt": prompt,
            "n": 1,
            "size": size,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let object = jsonObject(data),
                  let first = (object["data"] as? [[String: Any]])?.first else {
                let detail = String(decoding: data.prefix(300), as: UTF8.self)
                return ToolRunResult("Bildgenerierung fehlgeschlagen (HTTP \(status), Modell '\(settings.imageModel)'): \(detail)")
            }
            // Providers return either inline base64 or a URL.
            var pngData: Data?
            if let b64 = first["b64_json"] as? String { pngData = Data(base64Encoded: b64) }
            else if let remote = first["url"] as? String, let remoteURL = URL(string: remote) {
                pngData = try? await URLSession.shared.data(from: remoteURL).0
            }
            guard let pngData, let mediaId = MediaStore.saveImage(pngData: pngData) else {
                return ToolRunResult("Bildgenerierung lieferte keine nutzbaren Bilddaten")
            }
            return ToolRunResult("Bild erstellt und dem Nutzer angezeigt.", mediaIds: [mediaId])
        } catch {
            return ToolRunResult("Bildgenerierung fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}
