import Foundation

/// One entry from a provider's model list, with best-effort capability tags.
struct CatalogModel: Identifiable, Equatable, Hashable {
    var id: String
    var displayName: String
    var supportsTools: Bool
    var supportsVision: Bool
    /// Provider likely has /images or video generation for this stack (not per-id).
    var mediaGenerationLikely: Bool

    init(
        id: String,
        displayName: String? = nil,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        mediaGenerationLikely: Bool = false
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.mediaGenerationLikely = mediaGenerationLikely
    }

    var subtitle: String {
        var tags: [String] = []
        if supportsTools { tags.append("Tools") }
        if supportsVision { tags.append("Vision") }
        if mediaGenerationLikely { tags.append("Media") }
        if tags.isEmpty { tags.append("Chat") }
        return tags.joined(separator: " · ")
    }
}

/// Fetches and ranks live model lists. Shares URL/auth helpers with the chat path.
enum ModelCatalogService {

    private static func bearerToken(from key: String) -> String {
        key.hasPrefix(AuthStore.oauthMarker) ? String(key.dropFirst(AuthStore.oauthMarker.count)) : key
    }

    // MARK: - Public API

    static func fetchModels(settings: ProviderSettings, apiKey: String) async throws -> [CatalogModel] {
        // ChatGPT OAuth (Codex) has no public /models — curated list only.
        if settings.presetId == "openai", apiKey.hasPrefix(AuthStore.oauthMarker) {
            let models = ModelCatalogCache.codexOAuthModels()
            ModelCatalogCache.save(presetId: settings.presetId, models: models)
            return models
        }
        // Grok subscription authenticates only against the CLI proxy; api.x.ai's
        // /models rejects the subscription token — use a curated list instead.
        if settings.presetId == "xai", apiKey.hasPrefix(AuthStore.oauthMarker) {
            let models = ["grok-4", "grok-3", "grok-3-mini"].map {
                CatalogModel(id: $0, supportsTools: true)
            }
            ModelCatalogCache.save(presetId: settings.presetId, models: models)
            return models
        }
        do {
            let models: [CatalogModel]
            switch settings.preset.dialect {
            case .mlx:
                models = LocalModel.catalog.map {
                    CatalogModel(
                        id: $0.id,
                        displayName: $0.displayName,
                        supportsTools: true,
                        supportsVision: false,
                        mediaGenerationLikely: false
                    )
                }
            case .openai:
                models = try await fetchOpenAICompatible(settings: settings, apiKey: apiKey)
            case .anthropic:
                models = try await fetchAnthropic(settings: settings, apiKey: apiKey)
            }
            ModelCatalogCache.save(presetId: settings.presetId, models: models)
            return models
        } catch {
            // Soft-fail to cache / defaults so UI still works offline.
            if let cached = ModelCatalogCache.load(presetId: settings.presetId), !cached.isEmpty {
                return cached
            }
            let defaults = ModelCatalogCache.defaultModels(for: settings.presetId)
            if !defaults.isEmpty { return defaults }
            throw error
        }
    }

    /// Convenience: ids only (legacy callers / probes).
    static func fetchModelIds(settings: ProviderSettings, apiKey: String) async throws -> [String] {
        try await fetchModels(settings: settings, apiKey: apiKey).map(\.id)
    }

    /// Pick the best model id to activate after a successful list fetch.
    /// Prefers current selection if still present, else default, else first ranked.
    static func autoPickModel(
        from models: [CatalogModel],
        settings: ProviderSettings,
        preferTools: Bool = true
    ) -> String? {
        guard !models.isEmpty else { return nil }
        let ids = Set(models.map(\.id))
        if !settings.model.isEmpty, ids.contains(settings.model) {
            return settings.model
        }
        let def = settings.preset.defaultModel
        if !def.isEmpty, ids.contains(def) {
            return def
        }
        let ranked = rank(models, preferTools: preferTools, presetId: settings.presetId)
        return ranked.first?.id
    }

    /// Stable ranking: prefer tool-capable, then smaller/faster ids for locals, known good clouds first.
    static func rank(_ models: [CatalogModel], preferTools: Bool, presetId: String) -> [CatalogModel] {
        models.sorted { a, b in
            if preferTools, a.supportsTools != b.supportsTools {
                return a.supportsTools && !b.supportsTools
            }
            let sa = score(a.id, presetId: presetId)
            let sb = score(b.id, presetId: presetId)
            if sa != sb { return sa > sb }
            return a.id < b.id
        }
    }

    // MARK: - Fetch implementations

    private static func fetchOpenAICompatible(
        settings: ProviderSettings,
        apiKey: String
    ) async throws -> [CatalogModel] {
        // Never hit chatgpt.com Codex with /models — that path is inference-only.
        var listBase = settings.effectiveBaseURL
        if listBase.contains("chatgpt.com") || listBase.contains("cli-chat-proxy") {
            listBase = settings.preset.defaultBaseURL
        }
        // OAuth xAI uses proxy for chat; models still come from api.x.ai when possible.
        if settings.presetId == "xai", apiKey.hasPrefix(AuthStore.oauthMarker) {
            listBase = settings.preset.defaultBaseURL
        }
        guard !listBase.isEmpty else {
            let fallback = ModelCatalogCache.defaultModels(for: settings.presetId)
            if !fallback.isEmpty { return fallback }
            return []
        }
        guard let url = ProviderRequestSupport.endpoint(base: listBase, path: "/models") else {
            throw ProviderError.badResponse(0, "Ungültige Base-URL für Modelle.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Models list is JSON, not SSE — avoid event-stream Accept.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = bearerToken(from: apiKey)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if listBase.contains("openrouter.ai") {
            request.setValue("https://aiity.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("aiity", forHTTPHeaderField: "X-Title")
        }

        do {
            return try await performList(request, settings: settings, apiKey: apiKey)
        } catch {
            // Ollama native tags when OpenAI /models fails
            if ConnectionProbe.isLocalStyle(settings.presetId)
                || settings.presetId == "ollama",
               let tags = ConnectionProbe.ollamaTagsURL(from: listBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
                var tagsReq = URLRequest(url: tags)
                tagsReq.timeoutInterval = 15
                return try await performList(tagsReq, settings: settings, apiKey: apiKey)
            }
            throw error
        }
    }

    private static func fetchAnthropic(
        settings: ProviderSettings,
        apiKey: String
    ) async throws -> [CatalogModel] {
        let base = settings.baseURL(forKey: apiKey)
        guard !base.isEmpty else { return [] }
        guard let url = ProviderRequestSupport.endpoint(base: base, path: "/v1/models?limit=100")
                ?? ProviderRequestSupport.endpoint(base: base, path: "/v1/models") else {
            throw ProviderError.badResponse(0, "Ungültige Base-URL für Anthropic-Modelle.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let token = bearerToken(from: apiKey)
        if apiKey.hasPrefix(AuthStore.oauthMarker) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await performList(request, settings: settings, apiKey: apiKey)
    }

    private static func performList(
        _ request: URLRequest,
        settings: ProviderSettings,
        apiKey: String
    ) async throws -> [CatalogModel] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw ProviderError.fromHTTP(status: status, body: String(decoding: data.prefix(400), as: UTF8.self))
        }
        let raw = parseRawEntries(data)
        let mediaLikely = MediaCapability.supportsImageOrVideo(settings: settings, apiKey: apiKey)
        let mapped = raw.map { entry in
            enrich(id: entry.id, name: entry.name, settings: settings, mediaGenerationLikely: mediaLikely)
        }
        if mapped.isEmpty {
            throw ProviderError.badResponse(status, "Server meldet keine Modelle.")
        }
        return rank(mapped, preferTools: true, presetId: settings.presetId)
    }

    private struct RawEntry { var id: String; var name: String? }

    private static func parseRawEntries(_ data: Data) -> [RawEntry] {
        guard let object = jsonObject(data) else { return [] }
        // OpenAI / OpenRouter: { data: [ { id, name?, architecture? } ] }
        if let entries = object["data"] as? [[String: Any]] {
            return entries.compactMap { row in
                guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                return RawEntry(id: id, name: row["name"] as? String)
            }
        }
        // Ollama /api/tags: { models: [ { name, model } ] }
        if let models = object["models"] as? [[String: Any]] {
            return models.compactMap { row in
                let id = (row["name"] as? String) ?? (row["model"] as? String)
                guard let id, !id.isEmpty else { return nil }
                return RawEntry(id: id, name: id)
            }
        }
        return []
    }

    // MARK: - Capability heuristics

    static func enrich(
        id: String,
        name: String?,
        settings: ProviderSettings,
        mediaGenerationLikely: Bool
    ) -> CatalogModel {
        let lower = id.lowercased()
        let tools = inferTools(id: lower, presetId: settings.presetId)
        let vision = inferVision(id: lower)
        return CatalogModel(
            id: id,
            displayName: name ?? id,
            supportsTools: tools,
            supportsVision: vision,
            mediaGenerationLikely: mediaGenerationLikely && MediaCapability.modelLooksGenerative(id: lower)
        )
    }

    static func inferTools(id: String, presetId: String) -> Bool {
        // Models that almost never support function calling
        let noToolHints = ["embed", "whisper", "tts", "dall-e", "davinci", "babbage", "moderation", "clip"]
        if noToolHints.contains(where: { id.contains($0) }) { return false }
        // Tiny / base instruct without tool training (heuristic)
        if id.contains("1b") || id.contains("0.5b") { return false }
        if ConnectionProbe.isLocalStyle(presetId) {
            // Locals: optimistic true — OpenAICompatibleProvider retries without tools
            return true
        }
        return true
    }

    static func inferVision(id: String) -> Bool {
        id.contains("vision") || id.contains("gpt-4o") || id.contains("gemini")
            || id.contains("claude-3") || id.contains("claude-4") || id.contains("claude-sonnet")
            || id.contains("claude-opus") || id.contains("pixtral") || id.contains("llava")
    }

    /// True when an id looks like a text-chat model, not a specialised
    /// embeddings / audio / image / moderation / realtime model. Providers like
    /// OpenAI return the whole account catalog from `/models`, so without this
    /// the chat picker fills with `text-embedding-*`, `tts-*`, `whisper-*`,
    /// `dall-e-*`, `*-realtime-*` and `*-audio-*` ids that can't chat.
    /// Precise substrings only — a stray keep is better than hiding a real model.
    static func isLikelyChatModel(id: String) -> Bool {
        let l = id.lowercased()
        let nonChat = [
            "embedding", "text-embedding", "whisper", "-tts", "tts-",
            "text-to-speech", "-audio", "audio-", "transcribe", "dall-e",
            "dalle", "gpt-image", "moderation", "-realtime", "realtime-",
            "sora", "rerank",
        ]
        return !nonChat.contains { l.contains($0) }
    }

    /// Higher is better for auto-pick.
    private static func score(_ id: String, presetId: String) -> Int {
        let lower = id.lowercased()
        var s = 0
        // Prefer common “good defaults”
        if lower.contains("sonnet") { s += 50 }
        if lower.contains("gpt-4o") { s += 45 }
        if lower.contains("gpt-4.1") { s += 48 }
        if lower.contains("flash") { s += 40 }
        if lower.contains("mini") { s += 30 }
        if lower.contains("small") { s += 25 }
        if lower.contains("large") || lower.contains("opus") || lower.contains("pro") { s += 20 }
        if lower.contains("coder") || lower.contains("code") { s += 15 }
        if lower.contains("embed") || lower.contains("whisper") { s -= 100 }
        // Prefer non-preview for stability
        if lower.contains("preview") || lower.contains("exp") { s -= 10 }
        if presetId == "ollama" {
            // Prefer smaller tags for phone-facing latency when talking to a home server
            if lower.contains("7b") || lower.contains("8b") { s += 12 }
            if lower.contains("3b") || lower.contains("4b") { s += 10 }
            if lower.contains("70b") || lower.contains("72b") { s -= 5 }
        }
        return s
    }
}

/// Which providers can host image/video generation (separate modality slots).
enum MediaCapability {
    /// Cloud / gateway presets that expose OpenAI-style `/images` (or routing).
    static let imagePresetIds: Set<String> = [
        "openai", "openrouter", "custom-openai", "sub2api", "xai", "gemini",
    ]
    /// Video jobs are rarer; stick to known OpenAI-style video hosts.
    static let videoPresetIds: Set<String> = [
        "openai", "openrouter", "custom-openai", "sub2api",
    ]

    static func supportsImageGeneration(presetId: String) -> Bool {
        imagePresetIds.contains(presetId)
    }

    static func supportsVideoGeneration(presetId: String) -> Bool {
        videoPresetIds.contains(presetId)
    }

    static func supports(_ modality: ModelModality, presetId: String) -> Bool {
        switch modality {
        case .chat: return true
        case .image: return supportsImageGeneration(presetId: presetId)
        case .video: return supportsVideoGeneration(presetId: presetId)
        }
    }

    /// True when this connection can actually call image/video APIs with the given key.
    static func canUseMedia(presetId: String, apiKey: String, modality: ModelModality) -> Bool {
        guard supports(modality, presetId: presetId) else { return false }
        let preset = ProviderPreset.preset(for: presetId)
        if preset.dialect == .mlx { return false }
        // Pure LAN runtimes rarely implement /images or /videos.
        if ["ollama", "lmstudio", "localai"].contains(presetId) { return false }
        // ChatGPT OAuth uses Codex — no /images or /videos on that path.
        if presetId == "openai", apiKey.hasPrefix(AuthStore.oauthMarker) {
            return false
        }
        return true
    }

    /// Legacy helper: chat provider used for media (tests / catalog enrich).
    static func supportsImageOrVideo(settings: ProviderSettings, apiKey: String) -> Bool {
        canUseMedia(presetId: settings.presetId, apiKey: apiKey, modality: .image)
            || canUseMedia(presetId: settings.presetId, apiKey: apiKey, modality: .video)
    }

    static func modelLooksGenerative(id: String) -> Bool {
        id.contains("gpt-image") || id.contains("dall-e") || id.contains("sora")
            || id.contains("image") || id.contains("flux")
    }
}

/// Resolved endpoint for image or video generation (independent of chat).
struct MediaRoute: Equatable {
    var presetId: String
    var baseURL: String
    var model: String
    var apiKey: String

    /// Resolves the modality slot. Empty slot falls back to the chat provider
    /// when that provider can do media (migration path for older installs).
    static func resolve(modality: ModelModality, from settings: ProviderSettings) async -> MediaRoute? {
        guard modality == .image || modality == .video else { return nil }

        var presetId = settings.activePresetId(for: modality)
        if presetId.isEmpty {
            let chatId = settings.presetId
            if MediaCapability.supports(modality, presetId: chatId) {
                presetId = chatId
            } else {
                return nil
            }
        }
        guard MediaCapability.supports(modality, presetId: presetId) else { return nil }

        let connection = ProviderSettings.connectionSnapshot(presetId: presetId)
        let apiKey = await AuthStore.effectiveKey(for: connection)
        guard MediaCapability.canUseMedia(presetId: presetId, apiKey: apiKey, modality: modality) else {
            return nil
        }
        let model = settings.model(for: modality)
        return MediaRoute(
            presetId: presetId,
            baseURL: connection.baseURL(forKey: apiKey),
            model: model,
            apiKey: apiKey
        )
    }
}
