import Foundation

enum ProviderConnectionModel {
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
