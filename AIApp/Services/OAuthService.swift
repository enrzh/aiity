import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// PKCE OAuth engine for providers with a public flow. Two variants:
/// - standardPKCE (Anthropic "Sign in with Claude"): authorization code ->
///   bearer access/refresh tokens.
/// - openRouterKeyExchange: authorization code -> a plain API key.
/// Adding a provider is a ProviderPreset config entry, not code.
@MainActor
final class OAuthService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var busy = false

    enum Outcome {
        case apiKey(String)
        case credential(OAuthCredential)
    }

    enum OAuthError: LocalizedError {
        case cancelled
        case badCallback
        case missingClientId
        case exchangeFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Anmeldung abgebrochen."
            case .badCallback: return "Ungültige OAuth-Antwort."
            case .missingClientId: return "OAuth-Client-ID fehlt — erst beim Anbieter registrieren und eintragen."
            case .exchangeFailed(let detail): return "Token-Austausch fehlgeschlagen: \(detail)"
            }
        }
    }

    func signIn(preset: ProviderPreset, clientId: String) async throws -> Outcome {
        guard let config = preset.oauth else { throw OAuthError.badCallback }
        if config.needsClientId && clientId.isEmpty { throw OAuthError.missingClientId }
        busy = true
        defer { busy = false }

        let verifier = Self.randomToken()
        let state = Self.randomToken()
        let authorizeURL = Self.buildAuthorizeURL(config: config, clientId: clientId, state: state, verifier: verifier)
        let callback = try await presentBrowser(url: authorizeURL, callbackScheme: "aiapp")

        let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.badCallback
        }
        if config.flow == .standardPKCE {
            let returnedState = components?.queryItems?.first(where: { $0.name == "state" })?.value
            guard returnedState == nil || returnedState == state else { throw OAuthError.badCallback }
        }

        switch config.flow {
        case .openRouterKeyExchange:
            let object = try await Self.postJSON(config.tokenURL, body: [
                "code": code,
                "code_verifier": verifier,
                "code_challenge_method": "S256",
            ])
            guard let key = object["key"] as? String, !key.isEmpty else {
                throw OAuthError.exchangeFailed("keine key-Antwort")
            }
            return .apiKey(key)
        case .standardPKCE:
            let object = try await Self.postJSON(config.tokenURL, body: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": config.callback,
                "client_id": clientId,
                "code_verifier": verifier,
                "state": state,
            ])
            return .credential(try Self.credential(from: object))
        }
    }

    nonisolated static func refresh(config: OAuthProviderConfig, clientId: String, refreshToken: String) async throws -> OAuthCredential {
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        if !clientId.isEmpty { body["client_id"] = clientId }
        var object = try await postJSON(config.tokenURL, body: body)
        if object["refresh_token"] == nil { object["refresh_token"] = refreshToken }
        return try credential(from: object)
    }

    // MARK: - Helpers

    nonisolated static func buildAuthorizeURL(config: OAuthProviderConfig, clientId: String, state: String, verifier: String) -> URL {
        var components = URLComponents(string: config.authorizeURL)!
        var items: [URLQueryItem] = []
        switch config.flow {
        case .openRouterKeyExchange:
            items.append(URLQueryItem(name: "callback_url", value: config.callback))
        case .standardPKCE:
            items.append(URLQueryItem(name: "response_type", value: "code"))
            items.append(URLQueryItem(name: "client_id", value: clientId))
            items.append(URLQueryItem(name: "redirect_uri", value: config.callback))
            if !config.scopes.isEmpty {
                items.append(URLQueryItem(name: "scope", value: config.scopes))
            }
            items.append(URLQueryItem(name: "state", value: state))
        }
        items.append(URLQueryItem(name: "code_challenge", value: s256Challenge(of: verifier)))
        items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        components.queryItems = (components.queryItems ?? []) + items
        return components.url!
    }

    private func presentBrowser(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error, case ASWebAuthenticationSessionError.canceledLogin = error {
                    continuation.resume(throwing: OAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.badCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private nonisolated static func postJSON(_ urlString: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = jsonObject(data) else {
            throw OAuthError.exchangeFailed(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return object
    }

    private nonisolated static func credential(from object: [String: Any]) throws -> OAuthCredential {
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            throw OAuthError.exchangeFailed("kein access_token")
        }
        var expiresAt: Date?
        if let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue {
            expiresAt = Date().addingTimeInterval(expiresIn)
        }
        return OAuthCredential(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            expiresAt: expiresAt
        )
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    nonisolated static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    nonisolated static func s256Challenge(of verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
