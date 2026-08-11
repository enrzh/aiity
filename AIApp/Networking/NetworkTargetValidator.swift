import Foundation

/// Decides whether the app may fetch a given host, and re-decides it for every
/// redirect hop.
///
/// This is the single place that answers "is this address public?", because the
/// question is asked from three different transports — `URLSession` in
/// `FetchURLTool`, its redirect delegate, and the WebKit navigation policy in
/// `BrowserFetch`, which follows redirects itself. Three copies of an
/// SSRF check is three chances for one of them to drift.
///
/// The implementation currently lives in `FetchURLTool` and is exercised by an
/// existing test matrix (short-form and hex IPv4, IPv6 including IPv4-mapped,
/// userinfo and trailing-dot tricks). This type is the named seam the hardening
/// plan asks for; it deliberately delegates rather than reimplementing, so the
/// move carries no behaviour change and no risk of a weaker second copy.
enum NetworkTargetValidator {

    /// True when the host must not be fetched: loopback, RFC1918, link-local,
    /// CGNAT/Tailscale, `.local`, and the encodings that disguise them.
    static func isBlocked(host: String) -> Bool {
        FetchURLTool.isBlockedHost(host)
    }

    /// Whether a URL is an acceptable fetch target.
    ///
    /// - Parameter allowPrivate: true only when the *user's own* configured
    ///   runtime is local (their Ollama box, their gateway). It is never true
    ///   for arbitrary model-chosen URLs, which is the case SSRF is about.
    static func isAllowed(_ url: URL, allowPrivate: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        if allowPrivate { return true }
        return !isBlocked(host: url.host ?? "")
    }

    /// Returns a canonical public host suitable for a persisted app grant.
    /// URLs may include a path when entered in the permission sheet; bare host
    /// input must remain a single host, never a path or backslash payload.
    static func normalizeHost(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\\"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        let host: String
        if let components = URLComponents(string: value), let scheme = components.scheme {
            guard ["http", "https"].contains(scheme.lowercased()),
                  components.user == nil, components.password == nil,
                  !hasExplicitPort(in: components),
                  let urlHost = components.host else { return nil }
            host = urlHost
        } else {
            guard !value.contains("/"), !value.contains(":"),
                  let components = URLComponents(string: "https://\(value)"),
                  components.user == nil, components.password == nil,
                  !hasExplicitPort(in: components),
                  let urlHost = components.host else { return nil }
            host = urlHost
        }

        let lowercased = host.lowercased()
        guard !lowercased.hasPrefix(".") else { return nil }
        let normalized = lowercased.hasSuffix(".") ? String(lowercased.dropLast()) : lowercased
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !normalized.isEmpty,
              normalized.count <= 253,
              !isIPLiteral(normalized),
              labels.allSatisfy { label in
                  let value = String(label)
                  return !value.isEmpty && value.count <= 63
                      && !value.hasPrefix("-") && !value.hasSuffix("-")
                      && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              },
              !isBlocked(host: normalized) else { return nil }
        return normalized
    }

    /// Strict public-target validation plus this app's persisted host grant.
    /// Mini-app targets never accept IP literals, userinfo, or explicit ports.
    static func isAllowed(_ url: URL, allowPrivate: Bool, allowedHosts: [String]) -> Bool {
        guard isMiniAppTarget(url),
              let host = normalizeHost(url.host ?? "") else { return false }
        let normalizedAllowedHosts = Set(allowedHosts.compactMap(normalizeHost))
        return normalizedAllowedHosts.contains(host)
    }

    private static func isMiniAppTarget(_ url: URL) -> Bool {
        guard isAllowed(url, allowPrivate: false),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              !hasExplicitPort(in: components),
              !isIPLiteral(url.host ?? "") else { return false }
        return true
    }

    /// `URLComponents.port` is nil for an authority ending in `:`, so inspect
    /// the parsed authority as well to reject both empty and numeric ports.
    private static func hasExplicitPort(in components: URLComponents) -> Bool {
        if components.port != nil { return true }
        guard let serialized = components.string,
              let authorityStart = serialized.range(of: "://")?.upperBound else { return true }

        let authorityEnd = serialized[authorityStart...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? serialized.endIndex
        let authority = serialized[authorityStart..<authorityEnd]
        guard !authority.isEmpty else { return true }

        if authority.first == "[" {
            guard let closingBracket = authority.firstIndex(of: "]") else { return true }
            return authority.index(after: closingBracket) < authority.endIndex
        }
        return authority.contains(":")
    }

    private static func isIPLiteral(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":"), FetchURLTool.blockedIPv6(host) != nil { return true }
        if FetchURLTool.normalizedIPv4(host) != nil { return true }

        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let octet = Int(part) else { return false }
            return (0...255).contains(octet)
        }
    }

    /// Reason a target was refused, for surfacing to the model rather than
    /// failing opaquely — a tool result that explains itself stops the model
    /// retrying the same blocked URL.
    static func refusalReason(for url: URL, allowPrivate: Bool) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "Nur http(s)-Adressen werden geladen."
        }
        if !allowPrivate, isBlocked(host: url.host ?? "") {
            return "Blocked: refusing to fetch a private/LAN address (\(url.host ?? "?")). Only public web pages are allowed."
        }
        return nil
    }
}
