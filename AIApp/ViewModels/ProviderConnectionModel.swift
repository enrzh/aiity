import Foundation

enum ProviderConnectionModel {
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
