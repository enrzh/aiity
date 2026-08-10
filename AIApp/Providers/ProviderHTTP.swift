import Foundation

enum NetworkTransportError: LocalizedError, Equatable {
    case targetNotAllowed(URL)
    case cleartextNotAllowed(URL)
    case unsafeRedirect(URL)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .targetNotAllowed(let url):
            return NetworkTargetValidator.refusalReason(for: url, allowPrivate: false)
                ?? String(localized: "Ungültige Server-Adresse.")
        case .cleartextNotAllowed(let url):
            return HTTPPolicy.cleartextRefusal(for: url)
                ?? String(localized: "Unverschlüsseltes HTTP ist für diesen Server nicht erlaubt.")
        case .unsafeRedirect(let url):
            return String(localized: "Weiterleitung auf eine unsichere Server-Adresse abgelehnt: \(url.host ?? url.absoluteString)")
        case .invalidResponse:
            return String(localized: "Der Server hat keine gültige HTTP-Antwort geliefert.")
        }
    }
}

/// Validated URLSessions for provider traffic. Every request and redirect is
/// checked before credentials or prompt bodies can leave their original host.
enum ProviderHTTP {
    /// Performs short provider traffic after validating its initial destination
    /// and every redirect. `allowPrivate` is reserved for a provider endpoint
    /// the user configured themselves (LAN runtime, Tailscale peer or gateway).
    static func quickData(
        for request: URLRequest,
        allowPrivate: Bool
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw NetworkTransportError.invalidResponse }
        try validateQuickTarget(url, allowPrivate: allowPrivate)

        let (session, redirectValidator) = validatedSession(
            originURL: url,
            allowPrivate: allowPrivate,
            configuration: quickConfiguration(for: request)
        )
        defer { session.finishTasksAndInvalidate() }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            if let redirectError = redirectValidator.error {
                throw redirectError
            }
            throw error
        }
        if let redirectError = redirectValidator.error {
            throw redirectError
        }
        guard result.1 is HTTPURLResponse else {
            throw NetworkTransportError.invalidResponse
        }
        return result
    }

    /// Chat/completions SSE with the same target and redirect checks as short
    /// metadata calls, but with timeouts suitable for slow first tokens.
    static func streamingBytes(
        for request: URLRequest,
        allowPrivate: Bool
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        guard let url = request.url else { throw NetworkTransportError.invalidResponse }
        try validateQuickTarget(url, allowPrivate: allowPrivate)
        let (session, redirectValidator) = validatedSession(
            originURL: url,
            allowPrivate: allowPrivate,
            configuration: streamingConfiguration()
        )

        do {
            let result = try await session.bytes(for: request)
            session.finishTasksAndInvalidate()
            if let redirectError = redirectValidator.error { throw redirectError }
            guard result.1 is HTTPURLResponse else { throw NetworkTransportError.invalidResponse }
            return result
        } catch {
            session.invalidateAndCancel()
            throw redirectValidator.error ?? error
        }
    }

    /// Non-stream fallback for the same long-lived provider request path.
    static func streamingData(
        for request: URLRequest,
        allowPrivate: Bool
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw NetworkTransportError.invalidResponse }
        try validateQuickTarget(url, allowPrivate: allowPrivate)
        let (session, redirectValidator) = validatedSession(
            originURL: url,
            allowPrivate: allowPrivate,
            configuration: streamingConfiguration()
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            let result = try await session.data(for: request)
            if let redirectError = redirectValidator.error { throw redirectError }
            guard result.1 is HTTPURLResponse else { throw NetworkTransportError.invalidResponse }
            return result
        } catch {
            throw redirectValidator.error ?? error
        }
    }

    /// A private literal or local hostname is itself the explicit endpoint
    /// choice. Hosted public endpoints stay on the public-only policy.
    static func allowsPrivateEndpoint(_ url: URL) -> Bool {
        NetworkTargetValidator.isBlocked(host: url.host ?? "")
    }

    static func validateQuickTarget(_ url: URL, allowPrivate: Bool) throws {
        guard NetworkTargetValidator.isAllowed(url, allowPrivate: allowPrivate) else {
            throw NetworkTransportError.targetNotAllowed(url)
        }
        guard HTTPPolicy.allowsCleartext(for: url) else {
            throw NetworkTransportError.cleartextNotAllowed(url)
        }
    }

    static func validateRedirectTarget(
        _ url: URL,
        from originURL: URL,
        allowPrivate: Bool
    ) throws {
        do {
            try validateQuickTarget(url, allowPrivate: allowPrivate)
        } catch {
            throw NetworkTransportError.unsafeRedirect(url)
        }
        if !sameOrigin(originURL, url) {
            throw NetworkTransportError.unsafeRedirect(url)
        }
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func origin(_ url: URL) -> (scheme: String, host: String, port: Int?) {
            let scheme = url.scheme?.lowercased() ?? ""
            let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
            return (scheme, url.host?.lowercased() ?? "", url.port ?? defaultPort)
        }
        let left = origin(lhs)
        let right = origin(rhs)
        return left.scheme == right.scheme && left.host == right.host && left.port == right.port
    }

    private static func quickConfiguration(for request: URLRequest) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        let requestedTimeout = max(1, request.timeoutInterval)
        config.timeoutIntervalForRequest = min(45, requestedTimeout)
        config.timeoutIntervalForResource = min(60, requestedTimeout)
        // Metadata/probe UI must fail on its own deadline instead of waiting
        // minutes for connectivity. Streaming intentionally keeps waiting.
        config.waitsForConnectivity = false
        return config
    }

    private static func streamingConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 1_200
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 6
        return config
    }

    private static func validatedSession(
        originURL: URL,
        allowPrivate: Bool,
        configuration: URLSessionConfiguration
    ) -> (URLSession, ValidatedRedirectDelegate) {
        let validator = ValidatedRedirectDelegate(originURL: originURL, allowPrivate: allowPrivate)
        let session = URLSession(configuration: configuration, delegate: validator, delegateQueue: nil)
        return (session, validator)
    }
}

private final class ValidatedRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let originURL: URL
    private let allowPrivate: Bool
    private let lock = NSLock()
    private var rejectedRedirect: NetworkTransportError?

    init(originURL: URL, allowPrivate: Bool) {
        self.originURL = originURL
        self.allowPrivate = allowPrivate
    }

    var error: NetworkTransportError? {
        lock.lock()
        defer { lock.unlock() }
        return rejectedRedirect
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            record(.invalidResponse)
            completionHandler(nil)
            return
        }
        do {
            try ProviderHTTP.validateRedirectTarget(
                url,
                from: originURL,
                allowPrivate: allowPrivate
            )
            completionHandler(request)
        } catch {
            record(.unsafeRedirect(url))
            completionHandler(nil)
        }
    }

    private func record(_ error: NetworkTransportError) {
        lock.lock()
        rejectedRedirect = error
        lock.unlock()
    }
}
