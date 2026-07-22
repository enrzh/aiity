import Foundation

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

    /// Short calls: model list, OAuth token, probes.
    static let quick: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()
}
