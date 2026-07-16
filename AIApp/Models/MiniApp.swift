import Foundation
import SwiftData

/// A generated mini-app: a self-contained single-file HTML document that runs
/// inside the sandboxed runner web view. Iterations replace `html` and bump
/// `version`; the chat can reopen a mini-app to continue editing it.
@Model
final class MiniApp {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String
    var html: String
    var version: Int
    var createdAt: Date
    var updatedAt: Date

    init(name: String, emoji: String, html: String) {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.html = html
        self.version = 1
        self.createdAt = .now
        self.updatedAt = .now
    }
}
