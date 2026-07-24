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
        if !allowPrivateHosts, Self.isBlockedHost(url.host ?? "") {
            return ToolRunResult("Blocked: refusing to fetch a private/LAN address (\(url.host ?? "?")). Only public web pages are allowed.")
        }
        do {
            var request = URLRequest(url: url)
            request.setValue(WebSearchTool.browserUA, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            // A public URL can 302 to a private target; the initial-host check
            // above doesn't cover redirect hops, so use a session whose delegate
            // re-validates every hop when private hosts are disallowed.
            let blocker = allowPrivateHosts ? nil : SSRFRedirectBlocker()
            let session = URLSession(configuration: .ephemeral, delegate: blocker, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            if let blocked = blocker?.blockedHost {
                return ToolRunResult("Blocked: a redirect pointed at a private/LAN address (\(blocked)). Refusing to follow.")
            }
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let raw = String(decoding: data.prefix(600_000), as: UTF8.self)
            let text = contentType.contains("html") ? Self.extractText(fromHTML: raw) : raw
            return ToolRunResult(String(text.prefix(Self.maxCharacters)))
        } catch {
            return ToolRunResult("Fetch failed: \(error.localizedDescription)")
        }
    }

    /// Full block check: the string/range test below, plus non-standard IPv4
    /// encodings a dotted-quad parser misses (bare 32-bit integer like
    /// `2130706433` = 127.0.0.1, or hex `0x7f000001`).
    static func isBlockedHost(_ host: String) -> Bool {
        if isPrivateHost(host) { return true }
        if let dotted = normalizedIPv4(host), isPrivateHost(dotted) { return true }
        return false
    }

    /// Convert a bare-decimal or hex IPv4 host to dotted-quad; nil if it isn't one.
    static func normalizedIPv4(_ host: String) -> String? {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !h.isEmpty, !h.contains(".") else { return nil }
        let value: UInt64?
        if h.hasPrefix("0x") {
            value = UInt64(h.dropFirst(2), radix: 16)
        } else if h.allSatisfy(\.isNumber) {
            value = UInt64(h)
        } else {
            value = nil
        }
        guard let v = value, v <= 0xFFFF_FFFF else { return nil }
        return "\((v >> 24) & 255).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)"
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

/// Cancels any HTTP redirect whose target is a private/LAN host, closing the
/// redirect-based SSRF bypass (the initial-host guard alone can't see hops).
private final class SSRFRedirectBlocker: NSObject, URLSessionTaskDelegate {
    private(set) var blockedHost: String?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host ?? ""
        if FetchURLTool.isBlockedHost(host) {
            blockedHost = host
            completionHandler(nil)   // stop — do not fetch the private target
        } else {
            completionHandler(request)
        }
    }
}
