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
        var blockedRedirectHost: String?
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
            defer { blockedRedirectHost = blocker?.blockedHost }
            let session = URLSession(configuration: .ephemeral, delegate: blocker, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            if let blocked = blocker?.blockedHost {
                // Deliberately returns instead of falling through: the browser
                // fallback below would follow the very redirect just refused.
                return ToolRunResult("Blocked: a redirect pointed at a private/LAN address (\(blocked)). Refusing to follow.")
            }
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let raw = String(decoding: data.prefix(600_000), as: UTF8.self)
            let isHTML = contentType.contains("html")
            let text = isHTML ? Self.extractText(fromHTML: raw) : raw

            // A near-empty HTML page almost always means the content is built
            // client-side (or a bot wall was served). Re-fetch it in a real
            // browser, which runs the page's JavaScript.
            if isHTML, text.count < Self.thinPageThreshold {
                if let rendered = await Self.renderedText(for: url, allowPrivateHosts: allowPrivateHosts),
                   rendered.count > text.count {
                    return ToolRunResult(String(rendered.prefix(Self.maxCharacters)))
                }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ToolRunResult("Fetch returned no readable text for \(url.absoluteString).")
            }
            return ToolRunResult(String(text.prefix(Self.maxCharacters)))
        } catch {
            // Some sites reject non-browser clients outright; the browser path
            // is the natural retry rather than surfacing the failure. But a
            // request we cancelled OURSELVES for pointing at a private address
            // must never be retried through a transport that would allow it.
            if blockedRedirectHost != nil {
                return ToolRunResult("Blocked: a redirect pointed at a private/LAN address. Refusing to follow.")
            }
            if let rendered = await Self.renderedText(for: url, allowPrivateHosts: allowPrivateHosts) {
                return ToolRunResult(String(rendered.prefix(Self.maxCharacters)))
            }
            return ToolRunResult("Fetch failed: \(error.localizedDescription)")
        }
    }

    /// Below this many characters an HTML page is treated as unrendered — a
    /// real article virtually always clears it, a JS shell virtually never does.
    static let thinPageThreshold = 600

    /// Rendered text via WebKit. Returns nil on any failure so the caller can
    /// fall back to whatever the plain fetch produced.
    private static func renderedText(for url: URL, allowPrivateHosts: Bool) async -> String? {
        let fetcher = await BrowserFetch()
        return try? await fetcher.text(from: url, allowPrivateHosts: allowPrivateHosts)
    }

    /// Full block check: the string/range test below, plus non-standard IPv4
    /// encodings a dotted-quad parser misses (bare 32-bit integer like
    /// `2130706433` = 127.0.0.1, or hex `0x7f000001`).
    static func isBlockedHost(_ host: String) -> Bool {
        var h = host.lowercased().trimmingCharacters(in: .whitespaces)
        // Strip userinfo, brackets and a trailing root dot before classifying.
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        h = h.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while h.hasSuffix(".") { h.removeLast() }
        // IPv6: parse numerically rather than string-matching, so expanded forms
        // (0:0:0:0:0:0:0:1) and IPv4-mapped (::ffff:127.0.0.1) are caught too.
        if h.contains(":"), let verdict = blockedIPv6(h) { return verdict }
        if isPrivateHost(h) { return true }
        if let dotted = normalizedIPv4(h), isPrivateHost(dotted) { return true }
        return false
    }

    /// Numeric IPv6 classification via inet_pton. Returns nil when `host` isn't a
    /// valid IPv6 literal (caller falls through to the IPv4/name checks).
    /// Blocks loopback (::1 in any spelling), unspecified (::), link-local
    /// (fe80::/10), unique-local (fc00::/7), and IPv4-mapped/compatible addresses
    /// whose embedded IPv4 is private (::ffff:127.0.0.1).
    static func blockedIPv6(_ host: String) -> Bool? {
        var addr = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        let b = withUnsafeBytes(of: &addr) { Array($0) }
        guard b.count == 16 else { return nil }

        if b[0] == 0xfe, (b[1] & 0xc0) == 0x80 { return true }   // fe80::/10 link-local
        if (b[0] & 0xfe) == 0xfc { return true }                 // fc00::/7 unique-local

        let firstTwelveZero = b.prefix(10).allSatisfy { $0 == 0 }
        if firstTwelveZero {
            let mapped = b[10] == 0xff && b[11] == 0xff          // ::ffff:a.b.c.d
            let compat = b[10] == 0 && b[11] == 0                // ::a.b.c.d / ::1 / ::
            if mapped || compat {
                let v4 = "\(b[12]).\(b[13]).\(b[14]).\(b[15])"
                if compat, b[12] == 0, b[13] == 0, b[14] == 0, b[15] <= 1 {
                    return true                                   // :: and ::1
                }
                return isPrivateHost(v4)
            }
        }
        return false
    }

    /// Convert a non-dotted-quad IPv4 form to dotted-quad; nil if it isn't one.
    /// Handles a bare 32-bit integer (2130706433), hex (0x7f000001), octal
    /// (0177.0.0.1) and short forms (127.1) — all of which resolve to the same
    /// address a plain dotted-quad check would have blocked.
    static func normalizedIPv4(_ host: String) -> String? {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !h.isEmpty else { return nil }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 4, !parts.isEmpty else { return nil }

        var values: [UInt64] = []
        for part in parts {
            guard let v = parseIPv4Part(String(part)) else { return nil }
            values.append(v)
        }
        // Last part absorbs the remaining bytes (127.1 → 127.0.0.1).
        var address: UInt64 = 0
        let leading = values.dropLast()
        guard let tail = values.last else { return nil }
        let tailBytes = 4 - leading.count
        guard tailBytes >= 1, tail < (1 << (8 * UInt64(tailBytes))) else { return nil }
        for (i, v) in leading.enumerated() {
            guard v <= 255 else { return nil }
            address |= v << UInt64(8 * (3 - i))
        }
        address |= tail
        guard address <= 0xFFFF_FFFF else { return nil }
        let dotted = "\((address >> 24) & 255).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
        return dotted == h ? nil : dotted   // already plain dotted-quad → caller handled it
    }

    /// Parse one IPv4 component in decimal, hex (0x…) or octal (leading 0).
    private static func parseIPv4Part(_ part: String) -> UInt64? {
        if part.isEmpty { return nil }
        if part.hasPrefix("0x") { return UInt64(part.dropFirst(2), radix: 16) }
        if part.count > 1, part.hasPrefix("0") { return UInt64(part.dropFirst(), radix: 8) }
        return UInt64(part)
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

    #if DEBUG
    /// Test seam: lets a test show what the cheap path WOULD have produced,
    /// which is the whole point of the browser fallback.
    static func extractTextForTesting(fromHTML html: String) -> String {
        extractText(fromHTML: html)
    }
    #endif

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
