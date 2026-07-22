import Foundation
import SwiftData

/// A generated mini-app: HTML entry plus optional multi-file companions
/// (`filesJSON`). The runner always loads `bundledHTML` (CSS/JS inlined).
@Model
final class MiniApp {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String
    /// Optional SF Symbol name (e.g. `checklist`) — preferred over emoji in UI.
    var iconSymbol: String?
    var html: String
    /// JSON object path → source for multi-file packs; nil/`{}` when single-file.
    var filesJSON: String?
    var version: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        emoji: String,
        html: String,
        filesJSON: String = "{}",
        iconSymbol: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.iconSymbol = iconSymbol
        self.html = html
        self.filesJSON = filesJSON
        self.version = 1
        self.createdAt = .now
        self.updatedAt = .now
    }

    var bundle: MiniAppBundle {
        MiniAppBundle(
            name: name,
            emoji: emoji,
            html: html,
            files: MiniAppBundle.files(fromJSON: filesJSON),
            iconSymbol: iconSymbol
        )
    }

    /// HTML actually loaded in the sandbox (companions inlined).
    var runnableHTML: String { bundle.bundledHTML() }

    var capability: MiniAppCapability { MiniAppCapability.from(html: runnableHTML) }
}
