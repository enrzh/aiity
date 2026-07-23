import Foundation

/// Fetches a URL and returns readable text: HTML is stripped to visible text,
/// hard-capped so a giant page cannot blow up the model context.
struct FetchURLTool: AgentTool {
    private static let maxCharacters = 12_000
    /// Allow fetching private/LAN hosts. Only true when the chat provider itself
    /// is local (Ollama/LM Studio/self-hosted) — otherwise a prompt-injected page
    /// could steer the agent at the LAN / Tailscale NAS / cloud metadata.
    var allowPrivateHosts: Bool = false

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

    func run(argumentsJSON: String) async -> ToolRunResult {
        let urlString = toolArguments(argumentsJSON)["url"] as? String ?? ""
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme ?? "") else {
            return ToolRunResult("Error: invalid URL")
        }
        if !allowPrivateHosts, Self.isPrivateHost(url.host ?? "") {
            return ToolRunResult("Blocked: refusing to fetch a private/LAN address (\(url.host ?? "?")). Only public web pages are allowed.")
        }
        do {
            var request = URLRequest(url: url)
            request.setValue(WebSearchTool.browserUA, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let raw = String(decoding: data.prefix(600_000), as: UTF8.self)
            let text = contentType.contains("html") ? Self.extractText(fromHTML: raw) : raw
            return ToolRunResult(String(text.prefix(Self.maxCharacters)))
        } catch {
            return ToolRunResult("Fetch failed: \(error.localizedDescription)")
        }
    }

    /// True for loopback, private (RFC1918), link-local, CGNAT/Tailscale (100.64/10),
    /// and non-public hostnames (localhost, *.local/.internal/.lan, IPv6 ULA/link-local).
    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h.isEmpty { return true }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".lan") || h.hasSuffix(".home") || h.hasSuffix(".intranet") {
            return true
        }
        // IPv6 loopback / link-local (fe80::/10) / unique-local (fc00::/7)
        if h == "::1" || h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb")
            || h.hasPrefix("fc") || h.hasPrefix("fd") {
            return true
        }
        // IPv4 literal
        let parts = h.split(separator: ".")
        let octets = parts.compactMap { Int($0) }
        if parts.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            let a = octets[0], b = octets[1]
            if a == 127 || a == 10 || a == 0 { return true }        // loopback / private / this-host
            if a == 169 && b == 254 { return true }                 // link-local (incl. cloud metadata 169.254.169.254)
            if a == 192 && b == 168 { return true }                 // private
            if a == 172 && (16...31).contains(b) { return true }    // private
            if a == 100 && (64...127).contains(b) { return true }   // CGNAT / Tailscale
        }
        return false
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
