import Foundation

/// Web search for the agent. Preferred backend: a user-configured SearXNG
/// instance (JSON API). Fallback without any key: DuckDuckGo's HTML endpoint,
/// parsed leniently — good enough for research links, not a product API.
struct WebSearchTool: AgentTool {
    var searchEndpoint: String

    var spec: ToolSpec {
        ToolSpec(
            name: "web_search",
            description: "Search the web. Returns a list of result titles, URLs and snippets. Use fetch_url afterwards to read a promising result.",
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The search query"],
                ],
                "required": ["query"],
            ]
        )
    }

    func run(argumentsJSON: String) async -> String {
        let query = toolArguments(argumentsJSON)["query"] as? String ?? ""
        guard !query.isEmpty else { return "Error: empty query" }
        do {
            if !searchEndpoint.isEmpty {
                return try await searchViaSearxng(query)
            }
            return try await searchViaDuckDuckGo(query)
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }

    private func searchViaSearxng(_ query: String) async throws -> String {
        var components = URLComponents(string: searchEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let object = jsonObject(data),
              let results = object["results"] as? [[String: Any]] else {
            return "Search returned no parseable results."
        }
        return results.prefix(8).enumerated().map { index, result in
            let title = result["title"] as? String ?? "?"
            let url = result["url"] as? String ?? ""
            let snippet = (result["content"] as? String ?? "").prefix(200)
            return "\(index + 1). \(title)\n\(url)\n\(snippet)"
        }.joined(separator: "\n\n")
    }

    private func searchViaDuckDuckGo(_ query: String) async throws -> String {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (iPhone) AIApp/0.1", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(decoding: data, as: UTF8.self)

        // Lenient extraction of result anchors: <a class="result__a" href="...">Title</a>
        var results: [String] = []
        let pattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let match,
                  let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { return }
            var url = String(html[urlRange])
            // DDG wraps targets in a redirect: uddg=<encoded target>
            if let encoded = url.components(separatedBy: "uddg=").last?.components(separatedBy: "&").first,
               let decoded = encoded.removingPercentEncoding, decoded.hasPrefix("http") {
                url = decoded
            }
            let title = String(html[titleRange])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            results.append("\(results.count + 1). \(title)\n\(url)")
            if results.count >= 8 { stop.pointee = true }
        }
        return results.isEmpty ? "No results found." : results.joined(separator: "\n\n")
    }
}
