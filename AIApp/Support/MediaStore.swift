import Foundation

/// Stores generated media (images as PNG, videos as a small URL pointer) in
/// Application Support/media, keyed by an id that carries its kind via the
/// file extension. Chat messages reference media by id so they survive
/// restarts alongside the conversation.
enum MediaStore {
    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    enum Kind { case image, videoURL }

    static func kind(of mediaId: String) -> Kind {
        mediaId.hasSuffix(".videourl") ? .videoURL : .image
    }

    static func url(for mediaId: String) -> URL {
        directory.appendingPathComponent(mediaId)
    }

    static func saveImage(pngData: Data) -> String? {
        let id = "\(UUID().uuidString).png"
        do {
            try pngData.write(to: url(for: id), options: .atomic)
            return id
        } catch {
            return nil
        }
    }

    static func imageData(for mediaId: String) -> Data? {
        try? Data(contentsOf: url(for: mediaId))
    }

    static func saveVideoURL(_ remote: String) -> String? {
        let id = "\(UUID().uuidString).videourl"
        do {
            try Data(remote.utf8).write(to: url(for: id), options: .atomic)
            return id
        } catch {
            return nil
        }
    }

    static func videoURL(for mediaId: String) -> URL? {
        guard let data = try? Data(contentsOf: url(for: mediaId)) else { return nil }
        return URL(string: String(decoding: data, as: UTF8.self))
    }
}
