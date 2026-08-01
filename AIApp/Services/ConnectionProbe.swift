import Foundation

/// Outcome of a guided "Test connection" against a local or remote runtime.
struct ConnectionProbeResult: Equatable {
    var ok: Bool
    var models: [String]
    var reason: String
    /// Inferred from a tiny tool-call completion attempt when models list succeeds.
    var toolsLikely: Bool
    /// Models that are fine for chat/skills but not free-form Pro mini-apps.
    var chatOnly: Bool

    static func failure(_ reason: String) -> ConnectionProbeResult {
        ConnectionProbeResult(ok: false, models: [], reason: reason, toolsLikely: false, chatOnly: true)
    }
}

/// Message-carrying failure for probe parsers (`String` is not `Error` in Swift).
struct ProbeFailure: Error, Equatable {
    var message: String
}

/// Probes OpenAI-compatible (and Anthropic) endpoints: list models + short
/// non-stream completion. Pure response parsers are unit-tested; the network
/// path is thin and returns clear German/English error strings (no silent fail).
enum ConnectionProbe {

    /// Local LAN presets that get the first-class wizard treatment.
    static let localPresetIds: Set<String> = ["ollama", "lmstudio", "localai", "custom-openai", "sub2api"]

    static func isLocalStyle(_ presetId: String) -> Bool {
        localPresetIds.contains(presetId)
    }

    /// Soft capability profile used by the agent to steer mini-app generation.
    static func capabilities(for settings: ProviderSettings) -> (tools: Bool, miniAppPro: Bool) {
        switch settings.preset.dialect {
        case .mlx:
            return (tools: true, miniAppPro: false)
        case .anthropic:
            return (tools: true, miniAppPro: true)
        case .openai:
            if isLocalStyle(settings.presetId) || settings.presetId == "custom-openai" {
                return (tools: true, miniAppPro: false)
            }
            return (tools: true, miniAppPro: true)
        }
    }

    // MARK: - Pure parsers (shipped + tested)

    /// Interprets `GET …/models` (OpenAI) or Anthropic-shaped list bodies.
    static func parseModelsList(data: Data, statusCode: Int) -> Result<[String], ProbeFailure> {
        guard (200...299).contains(statusCode) else {
            let snippet = String(decoding: data.prefix(240), as: UTF8.self)
            return .failure(ProbeFailure(message: "Modelle laden fehlgeschlagen (HTTP \(statusCode))"
                            + (snippet.isEmpty ? "" : ": \(snippet)")))
        }
        guard let object = jsonObject(data) else {
            return .failure(ProbeFailure(message: String(localized: "Antwort ist kein gültiges JSON.")))
        }
        // OpenAI / Ollama OpenAI-compat: { "data": [ { "id": "…" } ] }
        if let entries = object["data"] as? [[String: Any]] {
            let ids = entries.compactMap { $0["id"] as? String }
            if ids.isEmpty { return .failure(ProbeFailure(message: "Server meldet keine Modelle (data[] leer).")) }
            return .success(ids.sorted())
        }
        // Native Ollama: { "models": [ { "name": "llama3" } ] } on /api/tags
        if let models = object["models"] as? [[String: Any]] {
            let ids = models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
            if ids.isEmpty { return .failure(ProbeFailure(message: "Ollama meldet keine Modelle.")) }
            return .success(ids.sorted())
        }
        return .failure(ProbeFailure(message: "Unerwartetes Modelle-JSON (weder data[] noch models[])."))
    }

    /// Interprets a non-stream chat/completions (or messages) response.
    static func parseCompletionProbe(data: Data, statusCode: Int) -> Result<String, ProbeFailure> {
        guard (200...299).contains(statusCode) else {
            let snippet = String(decoding: data.prefix(240), as: UTF8.self)
            return .failure(ProbeFailure(message: "Test-Chat fehlgeschlagen (HTTP \(statusCode))"
                            + (snippet.isEmpty ? "" : ": \(snippet)")))
        }
        guard let object = jsonObject(data) else {
            return .failure(ProbeFailure(message: "Test-Chat: Antwort ist kein JSON."))
        }
        // OpenAI chat.completion
        if let choices = object["choices"] as? [[String: Any]], let first = choices.first {
            if let message = first["message"] as? [String: Any],
               let content = message["content"] as? String, !content.isEmpty {
                return .success(content)
            }
            if let text = first["text"] as? String, !text.isEmpty {
                return .success(text)
            }
            // Some servers return empty content but still 200 — treat as OK
            return .success("(leer)")
        }
        // Anthropic messages
        if let content = object["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return .success(text) }
            return .success("(leer)")
        }
        return .failure(ProbeFailure(message: "Test-Chat: unerwartete Antwortform."))
    }

    // MARK: - Network probe

    /// Full test: normalize base URL → list models → short completion with first/default model.
    static func test(
        settings: ProviderSettings,
        apiKey: String,
        session: URLSession = .shared
    ) async -> ConnectionProbeResult {
        let dialect = settings.preset.dialect
        if dialect == .mlx {
            return ConnectionProbeResult(
                ok: true,
                models: LocalModel.catalog.map(\.id),
                reason: "On-Device MLX — Katalog geladen (\(LocalModel.catalog.count) Modelle). Mini-Apps: Template-Modus empfohlen.",
                toolsLikely: true,
                chatOnly: true
            )
        }

        let base = settings.effectiveBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let modelsURL = modelsListURL(base: base, dialect: dialect) else {
            return .failure(String(localized: "Keine Server-Adresse — z. B. http://192.168.1.10:11434 für Ollama."))
        }

        do {
            // Prefer unified catalog (same auth/headers as chat); fall back to legacy list.
            let models: [String]
            do {
                let catalog = try await ModelCatalogService.fetchModels(settings: settings, apiKey: apiKey)
                models = catalog.map(\.id)
            } catch {
                models = try await legacyListModels(
                    modelsURL: modelsURL, base: base, dialect: dialect, apiKey: apiKey, session: session
                )
            }

            let modelId = ModelCatalogService.autoPickModel(
                from: models.map { CatalogModel(id: $0) },
                settings: settings
            ) ?? models.first ?? ""
            guard !modelId.isEmpty else {
                return ConnectionProbeResult(
                    ok: false,
                    models: models,
                    reason: "Modelle gefunden (\(models.count)), aber keine Modell-ID zum Testen.",
                    toolsLikely: false,
                    chatOnly: isLocalStyle(settings.presetId)
                )
            }

            guard let completionReq = completionRequest(
                base: base, dialect: dialect, model: modelId, apiKey: apiKey
            ) else {
                return .failure("Konnte Test-Request nicht bauen.")
            }
            let (compData, compResponse) = try await session.data(for: completionReq)
            let compCode = (compResponse as? HTTPURLResponse)?.statusCode ?? 0
            switch parseCompletionProbe(data: compData, statusCode: compCode) {
            case .failure(let fail):
                return ConnectionProbeResult(
                    ok: false,
                    models: models,
                    reason: "Modelle ok (\(models.count)), aber Chat-Test: \(fail.message)",
                    toolsLikely: false,
                    chatOnly: true
                )
            case .success:
                let local = isLocalStyle(settings.presetId)
                return ConnectionProbeResult(
                    ok: true,
                    models: models,
                    reason: local
                        ? "Verbunden — \(models.count) Modelle. Chat/Skills ok; Mini-Apps im Template-Modus empfohlen."
                        : "Verbunden — \(models.count) Modelle, Test-Chat ok.",
                    toolsLikely: true,
                    chatOnly: local
                )
            }
        } catch {
            return .failure(NetworkErrorFriendly.message(for: error))
        }
    }


    private static func legacyListModels(
        modelsURL: URL,
        base: String,
        dialect: ProviderDialect,
        apiKey: String,
        session: URLSession
    ) async throws -> [String] {
        var listRequest = URLRequest(url: modelsURL)
        listRequest.timeoutInterval = 12
        applyAuth(to: &listRequest, apiKey: apiKey, dialect: dialect)
        let (listData, listResponse) = try await session.data(for: listRequest)
        let listCode = (listResponse as? HTTPURLResponse)?.statusCode ?? 0
        switch parseModelsList(data: listData, statusCode: listCode) {
        case .success(let ids):
            return ids
        case .failure(let fail):
            if dialect == .openai, let fallback = ollamaTagsURL(from: base) {
                var tagsReq = URLRequest(url: fallback)
                tagsReq.timeoutInterval = 12
                let (tagsData, tagsResp) = try await session.data(for: tagsReq)
                let tagsCode = (tagsResp as? HTTPURLResponse)?.statusCode ?? 0
                switch parseModelsList(data: tagsData, statusCode: tagsCode) {
                case .success(let ids): return ids
                case .failure(let r2):
                    throw ProviderError.badResponse(tagsCode, fail.message + " | " + r2.message)
                }
            }
            throw ProviderError.badResponse(listCode, fail.message)
        }
    }

    // MARK: - URL helpers

    static func modelsListURL(base: String, dialect: ProviderDialect) -> URL? {
        switch dialect {
        case .openai:
            return ProviderRequestSupport.endpoint(base: base, path: "/models")
        case .anthropic:
            return ProviderRequestSupport.endpoint(base: base, path: "/v1/models?limit=100")
                ?? ProviderRequestSupport.endpoint(base: base, path: "/v1/models")
        case .mlx:
            return nil
        }
    }

    /// If base is http://host:11434/v1 → http://host:11434/api/tags
    static func ollamaTagsURL(from base: String) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        let path = components.path
        if path.hasSuffix("/v1") {
            components.path = String(path.dropLast(2)) + "api/tags"
        } else if path.isEmpty || path == "/" {
            components.path = "/api/tags"
        } else {
            return nil
        }
        return components.url
    }

    private static func applyAuth(to request: inout URLRequest, apiKey: String, dialect: ProviderDialect) {
        let token = apiKey.hasPrefix(AuthStore.oauthMarker)
            ? String(apiKey.dropFirst(AuthStore.oauthMarker.count))
            : apiKey
        switch dialect {
        case .openai:
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        case .anthropic:
            if apiKey.hasPrefix(AuthStore.oauthMarker) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            } else if !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .mlx:
            break
        }
    }

    private static func completionRequest(
        base: String, dialect: ProviderDialect, model: String, apiKey: String
    ) -> URLRequest? {
        switch dialect {
        case .openai:
            guard let url = URL(string: "\(base)/chat/completions") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuth(to: &request, apiKey: apiKey, dialect: dialect)
            var body: [String: Any] = [
                "model": model,
                "stream": false,
                "messages": [["role": "user", "content": "Reply with exactly: ok"]],
            ]
            // gpt-5 / o-series reject `max_tokens` and require `max_completion_tokens`;
            // reuse the live path's tested branching so a valid key doesn't fail the
            // chat test just because a reasoning model is selected.
            OpenAICompatibleProvider.applyTokenLimit(&body, model: model, limit: 64)
            request.httpBody = jsonData(body)
            return request
        case .anthropic:
            guard let url = URL(string: "\(base)/v1/messages") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuth(to: &request, apiKey: apiKey, dialect: dialect)
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 8,
                "messages": [["role": "user", "content": "Reply with exactly: ok"]],
            ]
            request.httpBody = jsonData(body)
            return request
        case .mlx:
            return nil
        }
    }
}
