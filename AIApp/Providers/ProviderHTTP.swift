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

/// Shared URLSessions for provider traffic. Default `.shared` is too aggressive
/// for long Claude/Codex streams (idle timeout → “Zeitüberschreitung”).
enum ProviderHTTP {
    /// Chat/completions SSE: tolerate slow first token + long generations.
    static let streaming: URLSession = {
        let config = URLSessionConfiguration.default
        // Max silence between chunks (thinking / tool pauses).
        config.timeoutIntervalForRequest = 300
        // Whole turn including tools + long mini-app HTML.
        config.timeoutIntervalForResource = 1_200
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    /// Performs short provider traffic after validating its initial destination
    /// and every redirect. `allowPrivate` is reserved for a provider endpoint
    /// the user configured themselves (LAN runtime, Tailscale peer or gateway).
    static func quickData(
        for request: URLRequest,
        allowPrivate: Bool
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw NetworkTransportError.invalidResponse }
        try validateQuickTarget(url, allowPrivate: allowPrivate)

        let redirectValidator = ValidatedRedirectDelegate(allowPrivate: allowPrivate)
        let session = URLSession(
            configuration: quickConfiguration(),
            delegate: redirectValidator,
            delegateQueue: nil
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

    static func validateQuickTarget(_ url: URL, allowPrivate: Bool) throws {
        guard NetworkTargetValidator.isAllowed(url, allowPrivate: allowPrivate) else {
            throw NetworkTransportError.targetNotAllowed(url)
        }
        guard HTTPPolicy.allowsCleartext(for: url) else {
            throw NetworkTransportError.cleartextNotAllowed(url)
        }
    }

    private static func quickConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        return config
    }
}

private final class ValidatedRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let allowPrivate: Bool
    private let lock = NSLock()
    private var rejectedRedirect: NetworkTransportError?

    init(allowPrivate: Bool) {
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
            try ProviderHTTP.validateQuickTarget(url, allowPrivate: allowPrivate)
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
