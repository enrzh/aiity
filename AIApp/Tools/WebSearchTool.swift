import Foundation

/// Web search backends (user-configurable in Settings).
enum SearchBackend: String, Codable, CaseIterable, Identifiable {
    case auto
    case duckduckgo
    case searxng
    case brave
    case tavily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return String(localized: "Auto (beste verfügbar)")
        case .duckduckgo: return "DuckDuckGo (ohne Key)"
        case .searxng: return String(localized: "SearXNG")
        case .brave: return "Brave Search"
        case .tavily: return String(localized: "Tavily")
        }
    }
}

/// Web search for the agent. Backends: Auto cascade (Tavily → Brave → SearXNG → DDG),
/// or a forced backend. After results, the model should `fetch_url` top hits.
struct WebSearchTool: AgentTool {
    var searchEndpoint: String
    var backend: SearchBackend
    var braveKey: String
    var tavilyKey: String

    static let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    init(settings: ProviderSettings) {
        searchEndpoint = settings.searchEndpoint
        backend = SearchBackend(rawValue: settings.searchBackend) ?? .auto
        braveKey = Keychain.get("search-brave-key")
        tavilyKey = Keychain.get("search-tavily-key")
        // Allow keys stored only in settings fields when Keychain empty (tests).
        if braveKey.isEmpty { braveKey = settings.searchBraveKey }
        if tavilyKey.isEmpty { tavilyKey = settings.searchTavilyKey }
    }

    var spec: ToolSpec {
        ToolSpec(
            name: "web_search",
            description: "Search the web. Returns ranked titles, URLs and snippets. ALWAYS follow with fetch_url on the best 1–2 results before answering factual/current questions.",
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The search query"],
                ],
                "required": ["query"],
            ]
        )
    }

    func run(argumentsJSON: String) async -> ToolRunResult {
        let query = toolArguments(argumentsJSON)["query"] as? String ?? ""
        guard !query.isEmpty else { return ToolRunResult("Error: empty query") }
        do {
            let (results, source) = try await search(query)
            if results.isEmpty {
                return ToolRunResult("No results found for „\(query)“.")
            }
            let body = results.enumerated().map { index, r in
                var block = "\(index + 1). \(r.title)\n\(r.url)"
                if !r.snippet.isEmpty { block += "\n\(r.snippet)" }
                return block
            }.joined(separator: "\n\n")
            return ToolRunResult("Source: \(source)\n\n\(body)\n\nTip: call fetch_url on the most relevant URL(s) next.")
        } catch {
            return ToolRunResult("Search failed: \(error.localizedDescription)")
        }
    }

    struct Hit {
        var title: String
        var url: String
        var snippet: String
    }

    private func search(_ query: String) async throws -> ([Hit], String) {
        switch backend {
        case .tavily:
            return (try await searchTavily(query), "tavily")
        case .brave:
            return (try await searchBrave(query), "brave")
        case .searxng:
            return (try await searchSearxng(query), "searxng")
        case .duckduckgo:
            return (try await searchDuckDuckGo(query), "duckduckgo")
        case .auto:
            if !tavilyKey.isEmpty, let hits = try? await searchTavily(query), !hits.isEmpty {
                return (hits, "tavily")
            }
            if !braveKey.isEmpty, let hits = try? await searchBrave(query), !hits.isEmpty {
                return (hits, "brave")
            }
            if !searchEndpoint.isEmpty, let hits = try? await searchSearxng(query), !hits.isEmpty {
                return (hits, "searxng")
            }
            return (try await searchDuckDuckGo(query), "duckduckgo")
        }
    }

    private func searchSearxng(_ query: String) async throws -> [Hit] {
        var components = URLComponents(string: searchEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 18
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let object = jsonObject(data),
              let results = object["results"] as? [[String: Any]] else { return [] }
        return results.prefix(8).map { result in
            Hit(
                title: result["title"] as? String ?? "?",
                url: result["url"] as? String ?? "",
                snippet: String((result["content"] as? String ?? "").prefix(220))
            )
        }.filter { $0.url.hasPrefix("http") }
    }

    private func searchBrave(_ query: String) async throws -> [Hit] {
        guard !braveKey.isEmpty else { return [] }
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "8"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(braveKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 18
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let object = jsonObject(data) else {
            throw URLError(.badServerResponse)
        }
        let web = (object["web"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
        return web.prefix(8).map { r in
            Hit(
                title: r["title"] as? String ?? "?",
                url: r["url"] as? String ?? "",
                snippet: String((r["description"] as? String ?? "").prefix(220))
            )
        }.filter { $0.url.hasPrefix("http") }
    }

    private func searchTavily(_ query: String) async throws -> [Hit] {
        guard !tavilyKey.isEmpty else { return [] }
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = jsonData([
            "api_key": tavilyKey,
            "query": query,
            "max_results": 8,
            "include_answer": false,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let object = jsonObject(data),
              let results = object["results"] as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }
        return results.prefix(8).map { r in
            Hit(
                title: r["title"] as? String ?? "?",
                url: r["url"] as? String ?? "",
                snippet: String((r["content"] as? String ?? "").prefix(220))
            )
        }.filter { $0.url.hasPrefix("http") }
    }

    private func searchDuckDuckGo(_ query: String) async throws -> [Hit] {
        var request = URLRequest(url: URL(string: "https://lite.duckduckgo.com/lite/")!)
        request.httpMethod = "POST"
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: query)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        return Self.parseLiteHits(html)
    }

    static func parseLiteHits(_ html: String) -> [Hit] {
        var results: [Hit] = []
        let pattern = #"<a[^>]*href="([^"]+)"[^>]*class=['"]result-link['"][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let match,
                  let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { return }
            var url = String(html[urlRange]).replacingOccurrences(of: "&amp;", with: "&")
            if url.contains("uddg="),
               let encoded = url.components(separatedBy: "uddg=").last?.components(separatedBy: "&").first,
               let decoded = encoded.removingPercentEncoding, decoded.hasPrefix("http") {
                url = decoded
            }
            guard url.hasPrefix("http") else { return }
            let title = String(html[titleRange])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#x27;", with: "'")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(Hit(title: title, url: url, snippet: ""))
            if results.count >= 8 { stop.pointee = true }
        }
        return results
    }

    /// Legacy string parser used by tests.
    static func parseLiteResults(_ html: String) -> String {
        parseLiteHits(html).enumerated().map { i, h in
            "\(i + 1). \(h.title)\n\(h.url)"
        }.joined(separator: "\n\n")
    }
}
