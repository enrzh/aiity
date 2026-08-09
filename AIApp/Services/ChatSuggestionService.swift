import Foundation

/// Asks the user's OWN cloud provider for a couple of fresh mini-app ideas for
/// the chat empty state. Strictly optional garnish: it contributes at most
/// `ChatSuggestions.maxModelSuggestions` chips, the curated pool fills the
/// rest, and every failure path is silent (no banner, no retry).
///
/// Deliberate boundaries, all of them load-bearing:
///
/// * **Only an explicitly chosen model.** The gate reads `settings.model`, not
///   `effectiveModel`. Empty model means "the user has not picked one" (see
///   ProviderSettings.model) — a preset default is fine for a message the user
///   typed, but not for traffic nobody asked for.
/// * **API keys only.** A subscription OAuth credential is hard-excluded: that
///   path needs the Claude-CLI beta header, which this app decided not to
///   extend beyond user-initiated chat, and unattended calls would burn
///   429-prone plan quota.
/// * **No local runtimes.** MLX and the LAN presets keep the static chips —
///   they are the "non-local provider" condition anyway.
/// * **No user content leaves the device.** The prompt carries a bucketed
///   mini-app count and nothing else: no message text, no chat titles, no app
///   names. That is what keeps the privacy promise intact.
/// * **At most one call per launch and one per day**, capped at a handful of
///   tokens with a short timeout.
enum ChatSuggestionService {

    /// What is actually stored for the active provider account.
    enum CredentialKind {
        case none
        /// A plain API key — the only shape this feature will use.
        case apiKey
        /// A subscription/OAuth login. Hard-excluded, see above.
        case oauth
    }

    static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let cacheKey = "chat-suggestions-v1"
    /// Keep it cheap: a handful of noun phrases needs almost no tokens.
    private static let tokenLimit = 160
    private static let requestTimeout: TimeInterval = 12

    // MARK: - Gate (pure)

    /// The whole eligibility decision in one testable predicate.
    static func isEligible(
        settings: ProviderSettings,
        credential: CredentialKind,
        enabled: Bool
    ) -> Bool {
        guard enabled else { return false }
        // Covers MLX and every local-style preset (Ollama, LM Studio, LocalAI,
        // custom-openai, sub2api).
        guard !LocalRuntimePolicy.isLocal(settings) else { return false }
        guard settings.preset.dialect != .mlx else { return false }
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch credential {
        case .apiKey: return true
        case .none, .oauth: return false
        }
    }

    /// Resolves the credential SHAPE without touching the network — notably
    /// without `AuthStore.effectiveKey`, which would refresh an OAuth token
    /// (a request) just to find out this feature must not run.
    static func credentialKind(for settings: ProviderSettings) -> CredentialKind {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["AIITY_TEST_API_KEY"], !forced.isEmpty {
            return .apiKey
        }
        #endif
        guard let account = AccountStore.activeAccount(for: settings.presetId) else { return .none }
        if account.isOAuth || AuthStore.isOAuthConnected(account: account.keychainKey) { return .oauth }
        return Keychain.get(account.keychainKey).isEmpty ? .none : .apiKey
    }

    /// DEBUG kill switch so hermetic UI tests pointing a cloud preset at a
    /// local stub never fire suggestion traffic.
    static var disabledByEnvironment: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["AIITY_DISABLE_SUGGESTIONS"] == "1"
        #else
        return false
        #endif
    }

    // MARK: - Prompt (no user content)

    /// Coarse, non-identifying: four buckets, no exact number.
    static func experienceBucket(_ savedAppCount: Int) -> String {
        switch savedAppCount {
        case ..<1: return "noch keine"
        case 1...3: return "ein paar"
        case 4...9: return "einige"
        default: return "viele"
        }
    }

    static func prompt(savedAppCount: Int) -> String {
        """
        Du schlägst Ideen für kleine Mini-Apps vor, die als eine einzelne \
        HTML-Datei auf einem iPhone laufen. Der Nutzer hat \
        \(experienceBucket(savedAppCount)) Mini-Apps gespeichert.

        Antworte NUR mit einem JSON-Array aus genau \
        \(ChatSuggestions.maxModelSuggestions) kurzen deutschen Substantiv-Phrasen, \
        höchstens 22 Zeichen pro Eintrag, zum Beispiel \
        ["Schlaf-Tagebuch","Farb-Picker","Zungenbrecher"].

        Frische, alltagstaugliche Ideen, die offline funktionieren — ohne Login, \
        ohne Bezahldienst, ohne Konto. Keine Erklärungen, keine Nummerierung, \
        keine Emojis, kein Text außerhalb des Arrays.
        """
    }

    // MARK: - Request

    /// One-shot, non-streaming, tiny. Mirrors `ConnectionProbe.completionRequest`
    /// but with its own auth: only a plain key, never the OAuth beta header.
    static func request(settings: ProviderSettings, apiKey: String, prompt: String) -> URLRequest? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.hasPrefix(AuthStore.oauthMarker) else { return nil }
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        let base = settings.effectiveBaseURL

        switch settings.preset.dialect {
        case .openai:
            guard let url = URL(string: "\(base)/chat/completions") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = requestTimeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var body: [String: Any] = [
                "model": model,
                "stream": false,
                "messages": [["role": "user", "content": prompt]],
            ]
            // gpt-5 / o-series reject `max_tokens`; reuse the shipped branching.
            OpenAICompatibleProvider.applyTokenLimit(&body, model: model, limit: tokenLimit)
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return request
        case .anthropic:
            guard let url = URL(string: "\(base)/v1/messages") else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = requestTimeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let body: [String: Any] = [
                "model": model,
                "max_tokens": tokenLimit,
                "messages": [["role": "user", "content": prompt]],
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return request
        case .mlx:
            return nil
        }
    }

    // MARK: - Parsing (pure, lenient)

    /// Pulls the ideas out of a completion body. Anything unexpected yields an
    /// empty array — the caller then simply keeps the curated chips.
    static func parse(
        _ data: Data,
        dialect: ProviderDialect,
        limit: Int = ChatSuggestions.maxModelSuggestions
    ) -> [String] {
        guard let text = content(of: data, dialect: dialect) else { return [] }
        return sanitize(items(inJSONArrayWithin: text), limit: limit)
    }

    private static func content(of data: Data, dialect: ProviderDialect) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch dialect {
        case .openai, .mlx:
            let choices = root["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            return message?["content"] as? String
        case .anthropic:
            let blocks = root["content"] as? [[String: Any]]
            let texts = blocks?.compactMap { $0["text"] as? String } ?? []
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
    }

    /// First `[...]` in the text, decoded as strings. Fence- and prose-tolerant.
    private static func items(inJSONArrayWithin text: String) -> [String] {
        guard let start = text.firstIndex(of: "["),
              let end = text[start...].firstIndex(of: "]") else { return [] }
        let slice = String(text[start...end])
        if let decoded = try? JSONDecoder().decode([String].self, from: Data(slice.utf8)) {
            return decoded
        }
        // Some models answer with single quotes or trailing commas; fall back
        // to a plain split rather than throwing the whole answer away.
        return slice
            .dropFirst().dropLast()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'")) }
    }

    private static func sanitize(_ raw: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in raw {
            let item = candidate
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*•0123456789. \"'"))
            let key = ChatSuggestions.normalizedKey(item)
            guard !item.isEmpty, !key.isEmpty, item.count <= 30 else { continue }
            guard seen.insert(key).inserted else { continue }
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }

    // MARK: - Cache

    private struct Envelope: Codable {
        var savedAt: Date
        var presetId: String
        var model: String
        var suggestions: [String]
    }

    /// Cached ideas for exactly this preset+model, within the TTL.
    static func cached(
        presetId: String,
        model: String,
        now: Date = .now,
        defaults: UserDefaults = .standard
    ) -> [String]? {
        guard let data = defaults.data(forKey: cacheKey),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.presetId == presetId,
              envelope.model == model,
              !envelope.suggestions.isEmpty,
              now.timeIntervalSince(envelope.savedAt) < cacheTTL,
              envelope.savedAt <= now.addingTimeInterval(60)   // clock moved backwards
        else { return nil }
        return envelope.suggestions
    }

    static func store(
        _ suggestions: [String],
        presetId: String,
        model: String,
        now: Date = .now,
        defaults: UserDefaults = .standard
    ) {
        guard !suggestions.isEmpty else { return }
        let envelope = Envelope(
            savedAt: now, presetId: presetId, model: model, suggestions: suggestions
        )
        if let data = try? JSONEncoder().encode(envelope) {
            defaults.set(data, forKey: cacheKey)
        }
    }

    // MARK: - Entry point

    /// One attempt per launch, one successful fetch per day and provider.
    @MainActor private static var attemptedThisLaunch = false

    @MainActor
    static func suggestions(for settings: ProviderSettings, savedAppCount: Int) async -> [String]? {
        guard !disabledByEnvironment else { return nil }
        guard isEligible(
            settings: settings,
            credential: credentialKind(for: settings),
            enabled: AppPreferences.smartSuggestionsEnabled
        ) else { return nil }

        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = cached(presetId: settings.presetId, model: model) { return cached }
        guard !attemptedThisLaunch else { return nil }
        attemptedThisLaunch = true

        let apiKey = await AuthStore.effectiveKey(for: settings)
        guard let request = request(
            settings: settings, apiKey: apiKey, prompt: prompt(savedAppCount: savedAppCount)
        ) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            let items = parse(data, dialect: settings.preset.dialect)
            guard !items.isEmpty else { return nil }
            store(items, presetId: settings.presetId, model: model)
            return items
        } catch {
            return nil   // offline, timeout, 429 — the curated chips stay.
        }
    }

    #if DEBUG
    @MainActor
    static func resetLaunchThrottleForTesting() { attemptedThisLaunch = false }
    #endif
}
