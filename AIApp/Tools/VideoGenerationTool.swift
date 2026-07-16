import Foundation

/// Generates a video via the provider's OpenAI-style video jobs endpoint
/// (`{base}/videos` → poll `{base}/videos/{id}` until complete). Returns a
/// tappable link in the chat. Provider support for video varies and this path
/// could not be verified against a live backend — treat as best-effort.
struct VideoGenerationTool: AgentTool {
    var settings: ProviderSettings
    var apiKey: String

    private static let maxPolls = 60
    private static let pollInterval: UInt64 = 5_000_000_000 // 5s

    var spec: ToolSpec {
        ToolSpec(
            name: "generate_video",
            description: "Generate a short video from a text prompt (provider-dependent, takes a while). Use only when the user explicitly asks for a video.",
            parameters: [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "description": "Description of the video to generate"],
                ],
                "required": ["prompt"],
            ]
        )
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        let prompt = (toolArguments(argumentsJSON)["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return ToolRunResult("Error: empty prompt") }
        let base = settings.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let createURL = URL(string: "\(base)/videos") else {
            return ToolRunResult("Error: no video endpoint configured for this provider")
        }
        let token = bearerToken(from: apiKey)

        do {
            var create = URLRequest(url: createURL)
            create.httpMethod = "POST"
            create.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !token.isEmpty { create.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            create.httpBody = jsonData(["model": settings.videoModel, "prompt": prompt])
            let (data, response) = try await URLSession.shared.data(for: create)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  var job = jsonObject(data), let jobId = job["id"] as? String else {
                return ToolRunResult("Videogenerierung fehlgeschlagen: \(String(decoding: data.prefix(200), as: UTF8.self))")
            }

            // Poll until the job reports a terminal status.
            for _ in 0..<Self.maxPolls {
                let status = (job["status"] as? String ?? "").lowercased()
                if status == "completed" || status == "succeeded" {
                    if let remote = Self.extractVideoURL(job), let mediaId = MediaStore.saveVideoURL(remote) {
                        return ToolRunResult("Video fertiggestellt und dem Nutzer verlinkt.", mediaIds: [mediaId])
                    }
                    return ToolRunResult("Video fertig, aber keine URL im Ergebnis gefunden.")
                }
                if status == "failed" || status == "cancelled" {
                    return ToolRunResult("Videogenerierung abgebrochen (\(status)).")
                }
                try await Task.sleep(nanoseconds: Self.pollInterval)
                guard let pollURL = URL(string: "\(base)/videos/\(jobId)") else { break }
                var poll = URLRequest(url: pollURL)
                if !token.isEmpty { poll.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                let (pollData, _) = try await URLSession.shared.data(for: poll)
                if let updated = jsonObject(pollData) { job = updated }
            }
            return ToolRunResult("Video dauert länger als erwartet — bitte später erneut versuchen.")
        } catch {
            return ToolRunResult("Videogenerierung fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    private static func extractVideoURL(_ job: [String: Any]) -> String? {
        if let url = job["url"] as? String { return url }
        if let output = job["output"] as? [String: Any], let url = output["url"] as? String { return url }
        if let assets = job["assets"] as? [[String: Any]], let url = assets.first?["url"] as? String { return url }
        return nil
    }
}
