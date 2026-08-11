import Foundation

struct ProviderConnectionCandidate: Equatable {
    let presetId: String
    let baseURL: String
    let model: String
    let apiKey: String
}

enum ProviderConnectionValidationError: Error, Equatable, LocalizedError {
    case keyRequired
    case modelRequired
    case baseURLRequired
    case baseURLInvalid

    var errorDescription: String? {
        switch self {
        case .keyRequired:
            return String(localized: "API-Key erforderlich")
        case .modelRequired:
            return String(localized: "Modell-ID erforderlich")
        case .baseURLRequired:
            return String(localized: "Server-Adresse erforderlich")
        case .baseURLInvalid:
            return String(localized: "Server-Adresse ist ungültig")
        }
    }
}

enum ProviderConnectionModel {
    /// Builds an isolated connection attempt. Nothing in this method reads or
    /// writes persistence, which keeps invalid drafts and failed probes safe to
    /// retry.
    static func makeCandidate(
        preset: ProviderPreset,
        baseURL: String,
        model: String,
        apiKey: String
    ) -> Result<ProviderConnectionCandidate, ProviderConnectionValidationError> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.needsKey || !key.isEmpty else {
            return .failure(.keyRequired)
        }

        let chosenModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = chosenModel.isEmpty ? preset.defaultModel : chosenModel
        guard !normalizedModel.isEmpty else {
            return .failure(.modelRequired)
        }

        let rawURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL: String
        if preset.dialect == .mlx {
            normalizedURL = ""
        } else {
            guard !preset.editableBaseURL || !rawURL.isEmpty || !preset.defaultBaseURL.isEmpty else {
                return .failure(.baseURLRequired)
            }
            normalizedURL = ProviderSettings.normalizeBaseURL(
                rawURL.isEmpty ? preset.defaultBaseURL : rawURL,
                dialect: preset.dialect
            )
            guard isValidBaseURL(normalizedURL) else {
                return .failure(rawURL.isEmpty ? .baseURLRequired : .baseURLInvalid)
            }
        }

        return .success(ProviderConnectionCandidate(
            presetId: preset.id,
            baseURL: normalizedURL,
            model: normalizedModel,
            apiKey: key
        ))
    }

    static func shouldCommit(
        candidate: ProviderConnectionCandidate,
        probe: ConnectionProbeResult
    ) -> Bool {
        probe.ok
    }

    private static func isValidBaseURL(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    /// Whether leaving a provider screen should first ask the user to choose a
    /// model. True only when all of these hold:
    /// - chat modality (image keeps its own auto-pick behavior),
    /// - the preset actually reads `model` (MLX reads `localModelId` instead),
    /// - this provider IS the active chat provider (browsing a non-active
    ///   provider and leaving is always fine),
    /// - it is connected enough to chat (has an account, or needs no key),
    /// - and no model has been committed.
    ///
    /// The prompt only ASKS — leaving without a model stays allowed; chat
    /// surfaces a clear "Kein Modell gewählt" error for that state.
    static func needsModelChoice(
        preset: ProviderPreset,
        modality: ModelModality,
        isChatActive: Bool,
        committedModel: String,
        accountCount: Int
    ) -> Bool {
        guard modality == .chat, preset.dialect != .mlx, isChatActive else { return false }
        guard committedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return accountCount > 0 || !preset.needsKey
    }

    static func statusText(for preset: ProviderPreset, accountCount: Int) -> String {
        if preset.dialect == .mlx {
            return "On-Device"
        }

        switch accountCount {
        case 0:
            // OpenAI/xAI fall through to plain "API-Key" on their own now that
            // they carry no OAuth config.
            if preset.oauth?.flow == .pasteCode {
                return "API-Key · Abo optional"
            }
            return preset.oauthAvailable ? String(localized: "API-Key oder Login") : "API-Key"
        case 1:
            return "1 Konto"
        default:
            return "\(accountCount) Konten"
        }
    }
}
