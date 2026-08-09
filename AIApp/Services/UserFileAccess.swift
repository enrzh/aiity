import Foundation
import Combine

/// The documents the user picked for the agent — the ONLY files any tool can
/// reach.
///
/// Deliberate properties, each one load-bearing:
///
///  * **Session-scoped.** The bookmarks live in memory and are gone on the next
///    launch. "The agent may work with the files I just handed it" is a much
///    smaller promise than "the agent has standing access to my documents",
///    and it is the one the UI makes.
///  * **Picker-only.** Every entry originates in `UIDocumentPickerViewController`
///    (via SwiftUI's `fileImporter`). There is no path from a model-supplied
///    string to a URL: tools address files by the NAME shown in the list, which
///    is resolved against this table. A model cannot name its way to
///    `~/Library`, to the app container, or to the Keychain-backed stores —
///    those are not in the table, so they do not exist as far as a tool is
///    concerned.
///  * **Security-scoped, symmetrically.** Access is started and stopped around
///    every single read or write. Leaking a start is a real bug on iOS: the
///    sandbox extension count is finite per process.
@MainActor
final class UserFileAccess: ObservableObject {
    static let shared = UserFileAccess()

    struct Entry: Identifiable, Equatable {
        let id: UUID
        let name: String
        /// Security-scoped bookmark. Never written to disk.
        let bookmark: Data
        let addedAt: Date
    }

    @Published private(set) var entries: [Entry] = []

    /// Ceiling on how many documents can be shared at once. Keeps the tool
    /// result (and therefore the prompt) small, and keeps "select all" from
    /// turning into a bulk export.
    static let maxEntries = 20

    private init() {}

    // MARK: Picking

    enum AddResult: Equatable {
        case added(String)
        case duplicate(String)
        case failed(String)
    }

    /// Take ownership of a URL the user just picked. Returns what happened so
    /// the settings screen can say it rather than guess.
    @discardableResult
    func add(_ url: URL) -> AddResult {
        let name = url.lastPathComponent
        if entries.contains(where: { $0.name == name }) { return .duplicate(name) }
        guard entries.count < Self.maxEntries else {
            return .failed(String(localized: "Höchstens \(Self.maxEntries) Dateien gleichzeitig."))
        }
        // The picker hands over a security-scoped URL; the bookmark has to be
        // made while access is held, or it is worthless the moment the picker
        // goes away.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData()
            entries.append(Entry(id: UUID(), name: name, bookmark: bookmark, addedAt: .now))
            return .added(name)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func removeAll() {
        entries.removeAll()
    }

    var names: [String] { entries.map(\.name) }

    // MARK: Access

    enum FileError: LocalizedError, Equatable {
        case unknownName(String)
        case notReadable(String)
        case tooLarge(Int)
        case notText

        var errorDescription: String? {
            switch self {
            case .unknownName(let name):
                return String(localized: "Keine freigegebene Datei mit dem Namen „\(name)“.")
            case .notReadable(let message):
                return message
            case .tooLarge(let bytes):
                return String(localized: "Die Datei ist zu groß (\(bytes) Bytes).")
            case .notText:
                return String(localized: "Die Datei ist kein Text.")
            }
        }
    }

    /// Resolve by the name the model was shown, then run `body` with the
    /// security scope held for exactly that long.
    func withFile<T>(named name: String, _ body: (URL) throws -> T) throws -> T {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entry = entries.first(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) else {
            throw FileError.unknownName(trimmed)
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: entry.bookmark, bookmarkDataIsStale: &stale)
        } catch {
            throw FileError.notReadable(error.localizedDescription)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try body(url)
        } catch let error as FileError {
            throw error
        } catch {
            throw FileError.notReadable(error.localizedDescription)
        }
    }

    func readText(named name: String) throws -> String {
        try withFile(named: name) { url in
            let data = try Data(contentsOf: url)
            guard data.count <= PersonalToolLimits.maxFileBytes else {
                throw FileError.tooLarge(data.count)
            }
            guard let text = String(data: data, encoding: .utf8) else { throw FileError.notText }
            return String(text.prefix(PersonalToolLimits.maxFileCharacters))
        }
    }

    /// Overwrites a file the user picked. Only ever called after a confirmed
    /// `write_user_file`.
    func writeText(_ text: String, named name: String) throws {
        try withFile(named: name) { url in
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }

    /// Byte size, for the confirmation sheet and the file listing.
    func size(named name: String) -> Int? {
        try? withFile(named: name) { url in
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
    }
}

/// What the tools actually need from the table above — a snapshot plus the two
/// operations — so they can be tested without a document picker.
protocol UserFileProviding: AnyObject {
    func fileNames() async -> [String]
    func read(named name: String) async throws -> String
    func write(_ text: String, named name: String) async throws
}

/// Production adapter. Hops to the main actor because `UserFileAccess` is the
/// same object the settings screen observes.
final class MainActorUserFiles: UserFileProviding {
    static let shared = MainActorUserFiles()

    func fileNames() async -> [String] {
        await MainActor.run { UserFileAccess.shared.names }
    }

    func read(named name: String) async throws -> String {
        try await MainActor.run { try UserFileAccess.shared.readText(named: name) }
    }

    func write(_ text: String, named name: String) async throws {
        try await MainActor.run { try UserFileAccess.shared.writeText(text, named: name) }
    }
}
