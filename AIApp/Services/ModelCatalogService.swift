import Foundation

/// Fetches the live model list of the configured provider so the user picks
/// from real models instead of typing ids.
enum ModelCatalogService {
    /// Unwraps AuthStore's "oauth:<token>" marker to the bare token.
    private static func bearerToken(from key: String) -> String {
        key.hasPrefix(AuthStore.oauthMarker) ? String(key.dropFirst(AuthStore.oauthMarker.count)) : key
    }

    static func fetchModels(settings: ProviderSettings, apiKey: String) async throws -> [String] {
        switch settings.preset.dialect {
        case .mlx:
            return LocalModel.catalog.map(\.id)
        case .openai:
            let base = settings.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else { return [] }
            var request = URLRequest(url: URL(string: "\(base)/models")!)
            let token = bearerToken(from: apiKey)
            if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return try await requestIds(request)
        case .anthropic:
            let base = settings.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else { return [] }
            var request = URLRequest(url: URL(string: "\(base)/v1/models?limit=100")!)
            if apiKey.hasPrefix(AuthStore.oauthMarker) {
                request.setValue("Bearer \(bearerToken(from: apiKey))", forHTTPHeaderField: "Authorization")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            } else {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return try await requestIds(request)
        }
    }

    private static func requestIds(_ request: URLRequest) async throws -> [String] {
        var timed = request
        timed.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: timed)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0,
                                            String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let object = jsonObject(data),
              let entries = object["data"] as? [[String: Any]] else { return [] }
        return entries.compactMap { $0["id"] as? String }.sorted()
    }
}
