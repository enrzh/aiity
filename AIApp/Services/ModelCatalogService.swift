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
        if tags.isEmpty { tags.append(String(localized: "Chat")) }
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
            case .foundation:
                models = [CatalogModel(
                    id: settings.preset.defaultModel,
                    displayName: "Apple On-Device Model",
                    supportsTools: false
                )]
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
        // Every provider now lists models from its own public base URL — no
        // credential reroutes inference to a private backend any more, so there
        // is no second address to fall back to.
        let listBase = settings.effectiveBaseURL
        guard !listBase.isEmpty else {
            let fallback = ModelCatalogCache.defaultModels(for: settings.presetId)
            if !fallback.isEmpty { return fallback }
            return []
        }
        guard let url = ProviderRequestSupport.endpoint(base: listBase, path: "/models") else {
            throw ProviderError.badResponse(0, String(localized: "Ungültige Base-URL für Modelle."))
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
            if ConnectionProbe.isSelfHostedEndpoint(settings.presetId)
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
            throw ProviderError.badResponse(0, String(localized: "Ungültige Base-URL für Anthropic-Modelle."))
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
        let (data, response) = try await ProviderHTTP.quickData(
            for: request,
            allowPrivate: LocalRuntimePolicy.isSelfHosted(settings)
        )
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
            throw ProviderError.badResponse(status, String(localized: "Server meldet keine Modelle."))
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
        if ConnectionProbe.isSelfHostedEndpoint(presetId) {
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

/// Which providers can host image generation (its own modality slot).
enum MediaCapability {
    /// Cloud / gateway presets that expose OpenAI-style `/images` (or routing).
    static let imagePresetIds: Set<String> = [
        "openai", "openrouter", "custom-openai", "sub2api", "xai", "gemini",
    ]

    static func supportsImageGeneration(presetId: String) -> Bool {
        imagePresetIds.contains(presetId)
    }

    static func supports(_ modality: ModelModality, presetId: String) -> Bool {
        switch modality {
        case .chat: return true
        case .image: return supportsImageGeneration(presetId: presetId)
        }
    }

    /// True when this connection can actually call the image API with the given key.
    static func canUseMedia(presetId: String, apiKey: String, modality: ModelModality) -> Bool {
        guard supports(modality, presetId: presetId) else { return false }
        let preset = ProviderPreset.preset(for: presetId)
        if preset.dialect == .mlx { return false }
        // Pure LAN runtimes rarely implement /images.
        if ["ollama", "lmstudio", "localai"].contains(presetId) { return false }
        // A provider that needs a credential and has none can only ever answer
        // 401. Offering the model a tool whose every call is a guaranteed auth
        // error is worse than not offering it: it burns the tool budget and
        // ends the turn with an error instead of an answer.
        if preset.needsKey, bearerToken(from: apiKey).trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    /// Legacy helper: chat provider used for media (tests / catalog enrich).
    static func supportsImageOrVideo(settings: ProviderSettings, apiKey: String) -> Bool {
        canUseMedia(presetId: settings.presetId, apiKey: apiKey, modality: .image)
    }

    static func modelLooksGenerative(id: String) -> Bool {
        id.contains("gpt-image") || id.contains("dall-e")
            || id.contains("image") || id.contains("flux")
    }
}

/// Resolved endpoint for image generation (independent of chat).
struct MediaRoute: Equatable {
    var presetId: String
    var baseURL: String
    var model: String
    var apiKey: String

    /// Which provider serves this modality: the slot's own choice, else the
    /// chat provider when it can do media (migration path for older installs).
    /// Nil when nothing can.
    static func servingPresetId(modality: ModelModality, from settings: ProviderSettings) -> String? {
        guard modality == .image else { return nil }
        var presetId = settings.activePresetId(for: modality)
        if presetId.isEmpty { presetId = settings.presetId }
        guard MediaCapability.supports(modality, presetId: presetId) else { return nil }
        return presetId
    }

    /// Synchronous "could this possibly work?" — the same gates as `resolve`
    /// minus the async OAuth refresh. Used where a route cannot be awaited:
    /// deciding whether the system prompt may promise image generation at all.
    /// Promising a capability the model has no tool for makes it either
    /// hallucinate a picture it never made or apologise for a missing feature.
    static func canResolve(modality: ModelModality, from settings: ProviderSettings) -> Bool {
        guard let presetId = servingPresetId(modality: modality, from: settings) else { return false }
        return MediaCapability.canUseMedia(
            presetId: presetId,
            apiKey: AuthStore.storedKeySynchronously(presetId: presetId),
            modality: modality
        )
    }

    /// Resolves the modality slot. Empty slot falls back to the chat provider
    /// when that provider can do media (migration path for older installs).
    static func resolve(modality: ModelModality, from settings: ProviderSettings) async -> MediaRoute? {
        guard let presetId = servingPresetId(modality: modality, from: settings) else { return nil }

        let connection = ProviderSettings.connectionSnapshot(presetId: presetId)
        let apiKey = await AuthStore.effectiveKey(for: connection)
        guard MediaCapability.canUseMedia(presetId: presetId, apiKey: apiKey, modality: modality) else {
            return nil
        }
        let model = resolveModel(settings.model(for: modality), presetId: presetId, modality: modality)
        return MediaRoute(
            presetId: presetId,
            baseURL: connection.baseURL(forKey: apiKey),
            model: model,
            apiKey: apiKey
        )
    }

    /// Keep the configured model when the provider actually serves it; otherwise
    /// pick a generative model from that provider's catalog. Without this, a
    /// self-hosted gateway (sub2api) inherits the OpenAI-shaped default
    /// (`gpt-image-1`) and every generation 404s even though the gateway offers
    /// perfectly good image models (e.g. gemini-*-image).
    static func resolveModel(_ configured: String, presetId: String, modality: ModelModality) -> String {
        let catalog = ModelCatalogCache.modelsForDisplay(presetId: presetId).map(\.id)
        if catalog.isEmpty || catalog.contains(configured) { return configured }
        // Only substitute the built-in default. A model the user chose themselves
        // is kept even when absent from a possibly-stale cache — silently swapping
        // an explicit choice is worse than a clear "model not found" error.
        guard configured == modality.defaultModel else { return configured }
        // A video model is not an acceptable substitute for the image slot.
        let isVideo: (String) -> Bool = {
            let l = $0.lowercased()
            return l.contains("video") || l.contains("sora") || l.contains("veo")
        }
        let generative = catalog
            .filter { MediaCapability.modelLooksGenerative(id: $0.lowercased()) }
            .filter { !isVideo($0) }
        return generative.first ?? configured
    }
}
