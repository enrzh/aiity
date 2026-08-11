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
        if let url = URL(string: value), let scheme = url.scheme {
            guard ["http", "https"].contains(scheme.lowercased()),
                  url.user == nil, url.password == nil,
                  let urlHost = url.host, url.port == nil else { return nil }
            host = urlHost
        } else {
            guard !value.contains("/"), !value.contains(":"),
                  let url = URL(string: "https://\(value)"),
                  let urlHost = url.host, url.port == nil else { return nil }
            host = urlHost
        }

        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !normalized.isEmpty,
              normalized.count <= 253,
              labels.allSatisfy { label in
                  let value = String(label)
                  return !value.isEmpty && value.count <= 63
                      && !value.hasPrefix("-") && !value.hasSuffix("-")
                      && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              },
              !isBlocked(host: normalized) else { return nil }
        return normalized
    }

    /// Public-target validation plus this app's persisted host grant.
    static func isAllowed(_ url: URL, allowPrivate: Bool, allowedHosts: [String]) -> Bool {
        guard isAllowed(url, allowPrivate: false),
              let host = normalizeHost(url.host ?? "") else { return false }
        return allowedHosts.contains(host)
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
