import Foundation

/// Fetches the live model list of the configured provider so the user picks
/// from real models instead of typing ids.
enum ModelCatalogService {
    static func fetchModels(settings: ProviderSettings, apiKey: String) async throws -> [String] {
        switch settings.preset.dialect {
        case .mlx:
            return LocalModel.catalog.map(\.id)
        case .openai:
            let base = settings.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else { return [] }
            var request = URLRequest(url: URL(string: "\(base)/models")!)
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            return try await requestIds(request)
        case .anthropic:
            let base = settings.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !base.isEmpty else { return [] }
            var request = URLRequest(url: URL(string: "\(base)/v1/models?limit=100")!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
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
