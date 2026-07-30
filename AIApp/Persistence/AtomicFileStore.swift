import Foundation

/// Reads and writes one Codable value to one file, atomically, off the main
/// actor, and never destroys unreadable data.
///
/// Two properties matter more than the API surface:
///
/// **Atomic writes.** `Data.write(options: .atomic)` stages a temporary file and
/// renames it, so a crash or a kill mid-write leaves the previous file intact
/// rather than a truncated one. A half-written chat archive is indistinguishable
/// from a corrupt one, and the app persists on nearly every message.
///
/// **Corruption is quarantined, not overwritten.** When decoding fails the bytes
/// are moved to a timestamped sibling instead of being replaced by a fresh
/// empty value. That is the difference between "your history is in a file we
/// can name" and "your history is gone" — a distinction this codebase has
/// already been on the wrong side of once.
///
/// Being an actor keeps encoding and file I/O off the main thread; SwiftUI
/// stores call in with `await` and stay responsive while a large archive
/// serialises.
actor AtomicFileStore<Value: Codable & Sendable> {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter fileName: name inside Application Support.
    init(
        fileName: String,
        directory: URL? = nil,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = base.appendingPathComponent(fileName)
        self.encoder = encoder
        self.decoder = decoder
    }

    var fileURL: URL { url }

    /// Decode the stored value.
    ///
    /// - Throws: `.notFound` when nothing is stored yet (normal on first run),
    ///   `.corrupt` when bytes exist but cannot be decoded — in which case they
    ///   have already been quarantined and the caller may safely start empty.
    func load() throws -> Value {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RepositoryError.notFound
        }
        // An empty or whitespace-only file is a previous failed write, not
        // corruption worth keeping a copy of.
        guard data.count > 1 else { throw RepositoryError.notFound }

        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            let quarantined = quarantine(data)
            throw RepositoryError.corrupt(
                path: quarantined?.lastPathComponent ?? url.lastPathComponent,
                underlying: String(describing: error)
            )
        }
    }

    /// Load, or return `fallback` when nothing is stored. Corruption still
    /// throws — a caller that wants to continue anyway can catch it, but it
    /// must not be silently indistinguishable from an empty start.
    func load(orEmpty fallback: Value) throws -> Value {
        do {
            return try load()
        } catch let error as RepositoryError where error.isEmptyStart {
            return fallback
        }
    }

    func save(_ value: Value) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw RepositoryError.writeFailed(
                path: url.lastPathComponent,
                underlying: String(describing: error)
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            throw RepositoryError.writeFailed(
                path: url.lastPathComponent,
                underlying: String(describing: error)
            )
        }
    }

    /// Remove the stored file. Absence is success — deleting nothing is fine.
    func delete() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            throw RepositoryError.writeFailed(
                path: url.lastPathComponent,
                underlying: String(describing: error)
            )
        }
    }

    /// Move unreadable bytes aside so they can be recovered by hand, and so the
    /// next write starts from a clean file instead of appending to a mystery.
    private func quarantine(_ data: Data) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        do {
            try data.write(to: target, options: .atomic)
            try? FileManager.default.removeItem(at: url)
            return target
        } catch {
            return nil
        }
    }
}
