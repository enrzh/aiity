import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// PKCE OAuth for providers with a public, self-serve flow. OpenRouter is
/// implemented end-to-end: browser consent -> aiapp://oauth/openrouter
/// callback -> code exchange -> API key (stored by the caller in Keychain).
@MainActor
final class OAuthService: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var busy = false

    enum OAuthError: LocalizedError {
        case cancelled
        case badCallback
        case exchangeFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Anmeldung abgebrochen."
            case .badCallback: return "Ungültige OAuth-Antwort."
            case .exchangeFailed(let detail): return "Key-Austausch fehlgeschlagen: \(detail)"
            }
        }
    }

    func signIn(preset: ProviderPreset) async throws -> String {
        guard preset.id == "openrouter" else { throw OAuthError.badCallback }
        busy = true
        defer { busy = false }

        let verifier = Self.randomVerifier()
        let challenge = Self.s256Challenge(of: verifier)
        var components = URLComponents(string: "https://openrouter.ai/auth")!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: "aiapp://oauth/openrouter"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: "aiapp") { url, error in
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

        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.badCallback
        }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData([
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = jsonObject(data), let key = object["key"] as? String, !key.isEmpty else {
            throw OAuthError.exchangeFailed(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return key
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func s256Challenge(of verifier: String) -> String {
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
