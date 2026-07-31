import Foundation

/// Timeout, retry and cleartext rules in one place.
///
/// These numbers were previously literals scattered across the providers, the
/// catalog fetch, the probe and the tools — which is how a 120 s chat timeout
/// survived long enough to cut off real mini-app generations, and why the
/// cleartext rule ("HTTP only for a runtime the user configured themselves")
/// had to be re-derived at every call site.
enum HTTPPolicy {

    // MARK: - Timeouts

    /// A model streaming a long answer legitimately takes minutes. This is an
    /// IDLE-style ceiling for the whole request, not a promise of latency.
    static let streamingTimeout: TimeInterval = 600
    /// Metadata calls should fail fast — the user is waiting on a list.
    static let metadataTimeout: TimeInterval = 20
    /// Reading one web page for the agent.
    static let fetchTimeout: TimeInterval = 20
    /// A reachability probe must not hang the settings screen.
    static let probeTimeout: TimeInterval = 15

    // MARK: - Retry

    /// Attempts for a transfer that is expected to be interrupted (large model
    /// downloads on a phone). Ordinary API calls are NOT retried: a failed
    /// completion may already have been billed, and silently repeating it
    /// spends the user's money twice.
    static let interruptibleDownloadAttempts = 4

    /// Backoff before attempt `n` (1-based), so a flapping connection settles.
    static func backoff(forAttempt attempt: Int) -> TimeInterval {
        TimeInterval(max(1, attempt)) * 2
    }

    /// Transport-level failures worth another attempt. A 404 for a bad model id
    /// or a full disk is not — retrying those just delays the real error.
    static func isRetriable(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable,
            NSURLErrorDataNotAllowed,
        ].contains(ns.code)
    }

    // MARK: - Cleartext

    /// Whether plain HTTP is acceptable for this URL.
    ///
    /// The rule is about WHO chose the address, not about convenience. A
    /// self-hosted gateway, an Ollama box on the LAN or a Tailscale peer is the
    /// user's own machine, typed in by them, often without TLS — refusing that
    /// would make the bring-your-own-endpoint model unusable. A public host is
    /// a different matter: cleartext there is an eavesdropping risk the user
    /// did not opt into, and every hosted provider offers HTTPS.
    static func allowsCleartext(for url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return true }
        return NetworkTargetValidator.isBlocked(host: url.host ?? "")
    }

    /// Reason to show when cleartext is refused.
    static func cleartextRefusal(for url: URL) -> String? {
        allowsCleartext(for: url)
            ? nil
            : "Unverschlüsseltes HTTP ist nur für eigene Server im lokalen Netz erlaubt — \(url.host ?? "dieser Host") ist öffentlich erreichbar. Nutze https://."
    }
}
