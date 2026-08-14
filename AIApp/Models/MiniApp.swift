import Foundation
import SwiftData

/// A generated mini-app: HTML entry plus optional multi-file companions
/// (`filesJSON`). The runner always loads `bundledHTML` (CSS/JS inlined).
///
/// Shaped for CloudKit sync, which is stricter than a local-only store:
/// **no unique constraints** (CloudKit cannot enforce them across devices) and
/// **every attribute must be optional or carry a default**, because a record
/// arriving from another device may predate a property this build knows about.
/// `id` is therefore a plain attribute — uniqueness comes from generating a
/// UUID per instance, and last-writer-wins is the intended merge behaviour.
@Model
final class MiniApp {
    var id: UUID = UUID()
    var name: String = ""
    var emoji: String = "✨"
    /// Optional SF Symbol name (e.g. `checklist`) — preferred over emoji in UI.
    var iconSymbol: String?
    var html: String = ""
    /// JSON object path → source for multi-file packs; nil/`{}` when single-file.
    var filesJSON: String?
    var version: Int = 1
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

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

extension MiniApp {
    /// A duplicate for the remix flow. The initializer mints a fresh UUID, and
    /// that is the security property: consent grants, browser session stores
    /// and revision history are all keyed by id, so the copy starts with none
    /// of them. "Kopie" suffix per the German Finder/Pages duplicate idiom.
    func remixCopy() -> MiniApp {
        MiniApp(
            name: String(localized: "\(name) Kopie"),
            emoji: emoji,
            html: html,
            filesJSON: filesJSON ?? "{}",
            iconSymbol: iconSymbol
        )
    }
}
