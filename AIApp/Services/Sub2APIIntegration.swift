import Foundation

enum Sub2APIFeature: String, Codable, CaseIterable {
    case chat, tools, images, video, embeddings
}

struct Sub2APIModelDefaults: Codable, Equatable {
    var chat: String?
    var image: String?
    var video: String?
    var embedding: String?
}

struct Sub2APIManifest: Codable, Equatable {
    var apiVersion: Int
    var serverVersion: String?
    var openAIBaseURL: String
    var features: Set<Sub2APIFeature>
    var models: Sub2APIModelDefaults

    init(
        apiVersion: Int,
        serverVersion: String?,
        openAIBaseURL: String,
        features: Set<Sub2APIFeature>,
        models: Sub2APIModelDefaults
    ) {
        self.apiVersion = apiVersion
        self.serverVersion = serverVersion
        self.openAIBaseURL = openAIBaseURL
        self.features = features
        self.models = models
    }
}

struct Sub2APIModelMapping: Equatable {
    var chat: String?
    var image: String?
}

enum Sub2APIEnrollmentError: LocalizedError {
    case invalidPayload
    case unsafeCredential

    var errorDescription: String? {
        switch self {
        case .invalidPayload: return String(localized: "Der Einrichtungs-Code ist ungültig.")
        case .unsafeCredential: return String(localized: "Der Code enthält einen Admin-Schlüssel statt eines einmaligen Geräte-Tokens.")
        }
    }
}

struct Sub2APIEnrollmentPayload: Equatable {
    var gatewayURL: String
    var enrollmentToken: String
    var deviceName: String?

    static func parse(_ raw: String) throws -> Sub2APIEnrollmentPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           components.scheme?.lowercased() == "aiity",
           components.host?.lowercased() == "sub2api",
           components.path == "/enroll" {
            let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name.lowercased(), $0.value ?? "")
            })
            return try make(gateway: values["gateway"], token: values["token"], name: values["name"])
        }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Sub2APIEnrollmentError.invalidPayload
        }
        if object.keys.contains(where: { ["adminkey", "api_key", "apikey"].contains($0.lowercased()) }) {
            throw Sub2APIEnrollmentError.unsafeCredential
        }
        return try make(
            gateway: object["gateway"] as? String,
            token: object["token"] as? String,
            name: object["name"] as? String
        )
    }

    private static func make(gateway: String?, token: String?, name: String?) throws -> Self {
        guard let gateway, let token,
              !gateway.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Sub2APIEnrollmentError.invalidPayload
        }
        let normalized = ProviderSettings.normalizeBaseURL(gateway, dialect: .openai)
        guard URL(string: normalized)?.host != nil else { throw Sub2APIEnrollmentError.invalidPayload }
        return Self(
            gatewayURL: normalized,
            enrollmentToken: token.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceName: name?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct Sub2APIEnrollmentResult: Decodable, Equatable {
    var apiKey: String
    var label: String?
}

struct Sub2APIHealth: Codable, Equatable {
    var checkedAt: Date
    var ok: Bool
    var serverVersion: String?
    var latencyMilliseconds: Int?
    var modelCount: Int
    var failedStage: String?
    var message: String
}

struct Sub2APIHealthStore {
    static let storageKey = "sub2api-health-v1"
    var defaults: UserDefaults = .standard

    func load() -> Sub2APIHealth? {
        defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(Sub2APIHealth.self, from: $0) }
    }

    func save(_ health: Sub2APIHealth) {
        guard let data = try? JSONEncoder().encode(health) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

enum Sub2APIIntegration {
    static func gatewayRoot(baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        var path = components.path
        if path.hasSuffix("/v1") { path.removeLast(3) }
        components.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func manifestURL(baseURL: String) -> URL? {
        gatewayRoot(baseURL: baseURL)?.appendingPathComponent(".well-known/aiity")
    }

    static func enrollmentURL(baseURL: String) -> URL? {
        gatewayRoot(baseURL: baseURL)?.appendingPathComponent("api/aiity/enroll")
    }

    static func mapModels(_ ids: [String], manifest: Sub2APIManifest?) -> Sub2APIModelMapping {
        let available = Set(ids)
        let preferredChat = manifest?.models.chat.flatMap { available.contains($0) ? $0 : nil }
        let preferredImage = manifest?.models.image.flatMap { available.contains($0) ? $0 : nil }
        let image = preferredImage ?? ids.first { id in
            let value = id.lowercased()
            return value.contains("image") || value.contains("dall-e") || value.contains("flux")
        }
        let chat = preferredChat ?? ids.first { id in
            let value = id.lowercased()
            return id != image && !value.contains("embed") && !value.contains("rerank") && !value.contains("video")
        }
        return Sub2APIModelMapping(chat: chat, image: image)
    }

    static func discover(baseURL: String, apiKey: String) async -> Sub2APIManifest? {
        guard let url = manifestURL(baseURL: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await ProviderHTTP.quickData(for: request, allowPrivate: true),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(Sub2APIManifest.self, from: data)
    }

    static func enroll(_ payload: Sub2APIEnrollmentPayload) async throws -> Sub2APIEnrollmentResult {
        guard let url = enrollmentURL(baseURL: payload.gatewayURL) else {
            throw Sub2APIEnrollmentError.invalidPayload
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "token": payload.enrollmentToken,
            "deviceName": payload.deviceName ?? "iPhone",
        ])
        let (data, response) = try await ProviderHTTP.quickData(for: request, allowPrivate: true)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProbeFailure(message: String(localized: "Geräte-Token konnte nicht ausgestellt werden."))
        }
        return try JSONDecoder().decode(Sub2APIEnrollmentResult.self, from: data)
    }
}
