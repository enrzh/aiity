import Foundation

enum ProviderConnectionModel {
    static func statusText(for preset: ProviderPreset, accountCount: Int) -> String {
        if preset.dialect == .mlx {
            return "On-Device"
        }

        switch accountCount {
        case 0:
            if preset.id == "openai" || preset.id == "xai" {
                return "API-Key"
            }
            if preset.oauth?.flow == .pasteCode {
                return "API-Key · Abo optional"
            }
            return preset.oauthAvailable ? "API-Key oder Login" : "API-Key"
        case 1:
            return "1 Konto"
        default:
            return "\(accountCount) Konten"
        }
    }
}
