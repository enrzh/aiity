import Foundation

/// Disk cache of provider model lists so the picker is never empty until the
/// user taps “Modelle laden”. Seeded with known-good defaults per preset.
enum ModelCatalogCache {
    private static let prefix = "model-catalog-v1-"

    private struct Envelope: Codable {
        var savedAt: Date
        var models: [CatalogModelDTO]
    }

    private struct CatalogModelDTO: Codable {
        var id: String
        var displayName: String
        var supportsTools: Bool
        var supportsVision: Bool
        var mediaGenerationLikely: Bool

        init(_ m: CatalogModel) {
            id = m.id
            displayName = m.displayName
            supportsTools = m.supportsTools
            supportsVision = m.supportsVision
            mediaGenerationLikely = m.mediaGenerationLikely
        }

        var model: CatalogModel {
            CatalogModel(
                id: id,
                displayName: displayName,
                supportsTools: supportsTools,
                supportsVision: supportsVision,
                mediaGenerationLikely: mediaGenerationLikely
            )
        }
    }

    static func load(presetId: String) -> [CatalogModel]? {
        let key = cacheKey(presetId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let env = try? JSONDecoder().decode(Envelope.self, from: data),
              !env.models.isEmpty else {
            return nil
        }
        return env.models.map(\.model)
    }

    static func save(presetId: String, models: [CatalogModel]) {
        guard !models.isEmpty else { return }
        let env = Envelope(savedAt: .now, models: models.map(CatalogModelDTO.init))
        if let data = try? JSONEncoder().encode(env) {
            UserDefaults.standard.set(data, forKey: cacheKey(presetId))
        }
    }

    /// Immediate list for UI: cache → curated defaults → empty.
    static func modelsForDisplay(presetId: String) -> [CatalogModel] {
        if let cached = load(presetId: presetId), !cached.isEmpty {
            return cached
        }
        return defaultModels(for: presetId)
    }

    static func cacheKey(_ presetId: String) -> String {
        prefix + presetId
    }

    /// Known-good starter catalogs so pickers work offline / before first fetch.
    static func defaultModels(for presetId: String) -> [CatalogModel] {
        switch presetId {
        case "openai":
            return ids([
                "gpt-4.1", "gpt-4.1-mini", "gpt-4o", "gpt-4o-mini",
                "o3-mini", "o4-mini", "gpt-5", "gpt-5-mini",
            ])
        case "anthropic":
            return ids([
                "claude-sonnet-4-5", "claude-opus-4-5", "claude-haiku-4-5",
                "claude-sonnet-4-0", "claude-3-5-haiku-latest",
            ])
        case "openrouter":
            return ids([
                "openai/gpt-4o-mini", "openai/gpt-4.1", "anthropic/claude-sonnet-4",
                "google/gemini-2.0-flash-001", "meta-llama/llama-3.3-70b-instruct",
            ])
        case "gemini":
            return ids(["gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-1.5-pro"])
        case "mistral":
            return ids(["mistral-small-latest", "mistral-large-latest", "pixtral-large-latest"])
        case "groq":
            return ids(["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768"])
        case "deepseek":
            return ids(["deepseek-chat", "deepseek-reasoner"])
        case "xai":
            return ids(["grok-3", "grok-3-mini", "grok-2-latest"])
        case "together":
            return ids([
                "meta-llama/Llama-3.3-70B-Instruct-Turbo",
                "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo",
            ])
        case "mlx":
            return LocalModel.catalog.map {
                CatalogModel(id: $0.id, displayName: $0.displayName, supportsTools: true)
            }
        default:
            // custom / ollama / lmstudio — no fixed list
            return []
        }
    }

    private static func ids(_ list: [String], tools: Bool = true) -> [CatalogModel] {
        list.map { CatalogModel(id: $0, supportsTools: tools, supportsVision: $0.contains("4o") || $0.contains("gpt-5")) }
    }
}
