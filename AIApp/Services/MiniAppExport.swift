import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Exported by the app target (see the `UTExportedTypeDeclarations` /
    /// `CFBundleDocumentTypes` entries in project.yml): `.aiityapp`, a JSON
    /// envelope around one mini-app.
    static let aiityMiniApp = UTType(exportedAs: "com.aiity.miniapp", conformingTo: .json)
}

/// One mini-app as a single self-contained `.aiityapp` file — a JSON envelope
/// around the bundled HTML — for AirDrop / Files / Mail sharing and re-import.
///
/// Import grants NOTHING. The envelope carries no capability, consent or
/// host-grant data, and `makeMiniApp` mints a fresh UUID, so no consent record
/// can pre-exist for the imported app: its HTML runs in exactly the same
/// sandbox and first-open consent path as an AI-generated app. Nothing in this
/// file may ever call `MiniAppConsent`.
enum MiniAppExport {
    static let fileExtension = "aiityapp"
    static let formatVersion = 1
    /// A mini-app is one HTML document; anything beyond this is not one, and
    /// checking the size FIRST keeps a hostile file from being parsed at all.
    static let maxBytes = 2 * 1024 * 1024

    struct Envelope: Equatable {
        var formatVersion: Int
        var name: String
        var emoji: String
        var iconSymbol: String?
        var html: String
        var exportedAt: Date
    }

    enum ImportError: LocalizedError, Equatable {
        case tooLarge
        case unreadable
        case wrongFormat
        case unsupportedVersion
        case missingHTML

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return String(localized: "Die Datei ist zu groß für eine Mini-App (max. 2 MB).")
            case .unreadable:
                return String(localized: "Die Datei konnte nicht gelesen werden.")
            case .wrongFormat:
                return String(localized: "Das ist keine aiity Mini-App-Datei.")
            case .unsupportedVersion:
                return String(localized: "Diese App-Datei stammt aus einer neueren aiity-Version.")
            case .missingHTML:
                return String(localized: "Die App-Datei enthält keinen Inhalt.")
            }
        }
    }

    // MARK: - Encode

    /// Callers pass the RUNNABLE html (companions inlined): the file must open
    /// on a device that never sees `filesJSON`, so only the self-contained
    /// document round-trips.
    static func encode(
        name: String, emoji: String, iconSymbol: String?, html: String, exportedAt: Date = .now
    ) throws -> Data {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.missingHTML
        }
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "formatVersion": formatVersion,
            "name": name,
            "emoji": emoji,
            "html": html,
            "exportedAt": iso.string(from: exportedAt),
        ]
        if let iconSymbol, !iconSymbol.isEmpty { payload["iconSymbol"] = iconSymbol }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            throw ImportError.unreadable
        }
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        return data
    }

    /// Write the export to a temporary file and return its URL (for ShareLink)
    /// — same shape as `BackupService.writeBackup`.
    static func writeExport(name: String, emoji: String, iconSymbol: String?, html: String) -> URL? {
        guard let data = try? encode(name: name, emoji: emoji, iconSymbol: iconSymbol, html: html) else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(for: name))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// `<Name>.aiityapp`, with path-hostile characters stripped so the share
    /// sheet never receives a name that splits into directories.
    static func fileName(for name: String) -> String {
        var base = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        base = String(base.prefix(60))
        if base.isEmpty { base = "Mini-App" }
        return "\(base).\(fileExtension)"
    }

    // MARK: - Decode

    /// Read and validate an incoming file. Handles the security scope that
    /// Files / Mail hand over, and refuses an oversized file BEFORE reading it
    /// into memory — the byte check in `decode` alone would load it first.
    static func load(from url: URL) throws -> Envelope {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxBytes {
            throw ImportError.tooLarge
        }
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        return try decode(data)
    }

    /// Field-by-field like `BackupService.restore`, so each rejection names its
    /// actual reason instead of collapsing into one decoding error.
    static func decode(_ data: Data) throws -> Envelope {
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ImportError.unreadable
        }
        guard let version = object["formatVersion"] as? Int else { throw ImportError.wrongFormat }
        guard version <= formatVersion else { throw ImportError.unsupportedVersion }
        guard let html = object["html"] as? String,
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.missingHTML
        }
        let symbol = object["iconSymbol"] as? String
        return Envelope(
            formatVersion: version,
            name: object["name"] as? String ?? "Mini-App",
            emoji: object["emoji"] as? String ?? "✨",
            iconSymbol: (symbol?.isEmpty ?? true) ? nil : symbol,
            html: html,
            exportedAt: (object["exportedAt"] as? String)
                .flatMap(ISO8601DateFormatter().date(from:)) ?? .now
        )
    }

    /// A fresh record for an imported envelope. Always a NEW UUID, never one
    /// from the file: ids key consent grants and browser session stores, so an
    /// attacker-chosen id could inherit state from an app that once had it.
    static func makeMiniApp(from envelope: Envelope) -> MiniApp {
        MiniApp(
            name: String(envelope.name.prefix(80)),
            emoji: String(envelope.emoji.prefix(4)),
            html: envelope.html,
            filesJSON: "{}",
            iconSymbol: envelope.iconSymbol.map { String($0.prefix(64)) }
        )
    }
}

/// ShareLink payload that writes the `.aiityapp` file only when the user picks
/// a share destination — a context menu's content can be built for every tile,
/// and writing an export per render would do real I/O for menus never opened.
struct MiniAppShareItem: Transferable {
    var name: String
    var emoji: String
    var iconSymbol: String?
    var html: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .aiityMiniApp) { item in
            guard let url = MiniAppExport.writeExport(
                name: item.name, emoji: item.emoji, iconSymbol: item.iconSymbol, html: item.html
            ) else {
                throw MiniAppExport.ImportError.missingHTML
            }
            return SentTransferredFile(url)
        }
    }
}
