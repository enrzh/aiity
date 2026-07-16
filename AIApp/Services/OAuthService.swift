import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// OAuth engine ported from the sub2api gateway. Two flows:
/// - openRouterKeyExchange: browser redirect on a custom scheme -> API key.
/// - pasteCode: the CLI subscription flow (Codex CLI / Claude Code / grok-cli
///   client ids). The provider redirects to a localhost or hosted callback
///   that shows an authorization code; the user copies it back, then we run
///   the PKCE token exchange. Adding a provider is a ProviderPreset entry.
@MainActor
final class OAuthService: NSObject, ObservableObject {
    @Published var busy = false

    enum Outcome {
        case apiKey(String)
        case credential(OAuthCredential)
    }

    /// State carried between "open browser" and "paste the code".
    struct PendingPaste: Identifiable {
        let id = UUID()
        let presetId: String
        let verifier: String
        let state: String
        let authorizeURL: URL
    }

    enum OAuthError: LocalizedError {
        case cancelled
        case badCallback
        case noCode
        case exchangeFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Anmeldung abgebrochen."
            case .badCallback: return "Ungültige OAuth-Antwort."
            case .noCode: return "Kein Code erkannt — kopiere den Code (oder die ganze Weiterleitungs-URL) aus dem Browser."
            case .exchangeFailed(let detail): return "Token-Austausch fehlgeschlagen: \(detail)"
            }
        }
    }

    // MARK: - OpenRouter (custom-scheme redirect)

    func signInOpenRouter(preset: ProviderPreset) async throws -> Outcome {
        guard let config = preset.oauth, config.flow == .openRouterKeyExchange else {
            throw OAuthError.badCallback
        }
        busy = true
        defer { busy = false }

        let verifier = Self.randomToken()
        var components = URLComponents(string: config.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: config.redirectURI),
            URLQueryItem(name: "code_challenge", value: Self.s256Challenge(of: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let callback = try await presentBrowser(url: components.url!, callbackScheme: "aiapp")
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.noCode
        }
        let object = try await Self.postForm(config.tokenURL, contentType: .json, body: [
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256",
        ])
        guard let key = object["key"] as? String, !key.isEmpty else {
            throw OAuthError.exchangeFailed("keine key-Antwort")
        }
        return .apiKey(key)
    }

    // MARK: - Paste-code (CLI subscription flow)

    /// Step 1: build the authorize URL to open in the browser.
    nonisolated func startPasteFlow(preset: ProviderPreset) -> PendingPaste? {
        guard let config = preset.oauth, config.flow == .pasteCode else { return nil }
        let verifier = Self.randomToken()
        let state = Self.randomToken()

        var components = URLComponents(string: config.authorizeURL)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.s256Challenge(of: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if config.usesNonce {
            items.append(URLQueryItem(name: "nonce", value: Self.randomToken()))
        }
        for (key, value) in config.extraAuthParams.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = (components.queryItems ?? []) + items
        guard let url = components.url else { return nil }
        return PendingPaste(presetId: preset.id, verifier: verifier, state: state, authorizeURL: url)
    }

    /// Step 2: exchange the pasted code/URL for tokens.
    func completePasteFlow(_ pending: PendingPaste, pasted: String) async throws -> Outcome {
        guard let config = ProviderPreset.preset(for: pending.presetId).oauth else {
            throw OAuthError.badCallback
        }
        busy = true
        defer { busy = false }

        let (code, stateFromInput) = Self.parseAuthorizationInput(pasted)
        guard !code.isEmpty else { throw OAuthError.noCode }

        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "client_id": config.clientId,
            "code_verifier": pending.verifier,
        ]
        // Claude echoes the state appended to the code (authCode#state) and
        // wants it back in the exchange.
        let state = stateFromInput ?? pending.state
        if !state.isEmpty { body["state"] = state }

        let object = try await Self.postForm(config.tokenURL,
                                             contentType: config.tokenBody == .json ? .json : .form,
                                             body: body)
        return .credential(try Self.credential(from: object))
    }

    // MARK: - Refresh

    nonisolated static func refresh(config: OAuthProviderConfig, refreshToken: String) async throws -> OAuthCredential {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientId,
        ]
        var object = try await postForm(config.tokenURL,
                                        contentType: config.tokenBody == .json ? .json : .form,
                                        body: body)
        if object["refresh_token"] == nil { object["refresh_token"] = refreshToken }
        return try credential(from: object)
    }

    // MARK: - Parsing / HTTP

    /// Accepts a bare code, a "code#state" pair (Claude), or a full redirect
    /// URL whose query holds code/state (localhost callbacks).
    nonisolated static func parseAuthorizationInput(_ raw: String) -> (code: String, state: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), components.scheme != nil,
           let items = components.queryItems {
            let code = items.first(where: { $0.name == "code" })?.value ?? ""
            let state = items.first(where: { $0.name == "state" })?.value
            if !code.isEmpty { return (code, state) }
        }
        if let hashIndex = trimmed.firstIndex(of: "#") {
            let code = String(trimmed[..<hashIndex])
            let state = String(trimmed[trimmed.index(after: hashIndex)...])
            return (code, state.isEmpty ? nil : state)
        }
        return (trimmed, nil)
    }

    enum ContentType { case json, form }

    private nonisolated static func postForm(_ urlString: String, contentType: ContentType, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        switch contentType {
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonData(body)
        case .form:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = jsonObject(data) else {
            throw OAuthError.exchangeFailed(String(decoding: data.prefix(240), as: UTF8.self))
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

    // MARK: - Browser + PKCE

    private func presentBrowser(url: URL, callbackScheme: String) async throws -> URL {
        let anchor = ContextProvider()
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error, case ASWebAuthenticationSessionError.canceledLogin = error {
                    continuation.resume(throwing: OAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.badCallback)
                }
            }
            session.presentationContextProvider = anchor
            self.anchor = anchor
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private var anchor: ContextProvider?

    nonisolated static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    nonisolated static func s256Challenge(of verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

private final class ContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
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
