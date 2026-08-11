import Foundation

struct ChatAttachment: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image
        case file
    }

    var id: UUID
    var mediaId: String
    var filename: String
    var mimeType: String
    var kind: Kind

    init(
        id: UUID = UUID(),
        mediaId: String,
        filename: String,
        mimeType: String,
        kind: Kind
    ) {
        self.id = id
        self.mediaId = mediaId
        self.filename = filename
        self.mimeType = mimeType
        self.kind = kind
    }
}
