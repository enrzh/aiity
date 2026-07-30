import Foundation

/// What a provider+model slot is used for. Chat and image generation are
/// independent active selections, so media is not nested inside a chat
/// provider.
///
/// Video generation was removed: the OpenAI-style `/videos` job endpoint is
/// served by almost nothing an ordinary API key can reach, so the slot was a
/// permanently empty configuration surface.
enum ModelModality: String, Codable, CaseIterable, Identifiable {
    case chat
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .image: return "Bild"
        }
    }

    var sectionTitle: String {
        switch self {
        case .chat: return "Chat"
        case .image: return "Bildgenerierung"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .image: return "photo"
        }
    }

    var useButtonTitle: String {
        switch self {
        case .chat: return "Für den Chat verwenden"
        case .image: return "Für Bilder verwenden"
        }
    }

    var activeLabel: String {
        switch self {
        case .chat: return "Wird im Chat verwendet"
        case .image: return "Wird für Bilder verwendet"
        }
    }

    var modelSectionTitle: String {
        switch self {
        case .chat: return "Chat-Modell"
        case .image: return "Bild-Modell"
        }
    }

    var defaultModel: String {
        switch self {
        case .chat: return ""
        case .image: return "gpt-image-1"
        }
    }
}
