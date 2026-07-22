import Foundation

/// What a provider+model slot is used for. The app keeps independent active
/// selections for chat, image generation, and video generation so media is not
/// nested inside a chat provider.
enum ModelModality: String, Codable, CaseIterable, Identifiable {
    case chat
    case image
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .image: return "Bild"
        case .video: return "Video"
        }
    }

    var sectionTitle: String {
        switch self {
        case .chat: return "Chat"
        case .image: return "Bildgenerierung"
        case .video: return "Videogenerierung"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .image: return "photo"
        case .video: return "video"
        }
    }

    var useButtonTitle: String {
        switch self {
        case .chat: return "Für den Chat verwenden"
        case .image: return "Für Bilder verwenden"
        case .video: return "Für Videos verwenden"
        }
    }

    var activeLabel: String {
        switch self {
        case .chat: return "Wird im Chat verwendet"
        case .image: return "Wird für Bilder verwendet"
        case .video: return "Wird für Videos verwendet"
        }
    }

    var modelSectionTitle: String {
        switch self {
        case .chat: return "Chat-Modell"
        case .image: return "Bild-Modell"
        case .video: return "Video-Modell"
        }
    }

    var defaultModel: String {
        switch self {
        case .chat: return ""
        case .image: return "gpt-image-1"
        case .video: return "sora-2"
        }
    }
}
