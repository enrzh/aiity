import Foundation

/// Fetches a URL and returns readable text: HTML is stripped to visible text,
/// hard-capped so a giant page cannot blow up the model context.
struct FetchURLTool: AgentTool {
    private static let maxCharacters = 12_000

    var spec: ToolSpec {
        ToolSpec(
            name: "fetch_url",
            description: "Fetch a web page and return its readable text content (truncated). Use after web_search to read a result.",
            parameters: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Absolute http(s) URL to fetch"],
                ],
                "required": ["url"],
            ]
        )
    }

    func run(argumentsJSON: String) async -> String {
        let urlString = toolArguments(argumentsJSON)["url"] as? String ?? ""
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme ?? "") else {
            return "Error: invalid URL"
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone) AIApp/0.1", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let raw = String(decoding: data.prefix(600_000), as: UTF8.self)
            let text = contentType.contains("html") ? Self.extractText(fromHTML: raw) : raw
            return String(text.prefix(Self.maxCharacters))
        } catch {
            return "Fetch failed: \(error.localizedDescription)"
        }
    }

    private static func extractText(fromHTML html: String) -> String {
        var text = html
        for pattern in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#, #"<[^>]+>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
        return text.replacingOccurrences(of: #"\s{2,}"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
