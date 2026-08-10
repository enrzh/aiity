import Foundation

/// Owns the on-disk chat archive. The UI hands it immutable snapshots; this
/// actor serialises, coalesces and atomically writes them away from MainActor.
actor ChatThreadRepository {
    static let currentVersion = 1

    struct Snapshot: Codable, Equatable, Sendable {
        var threads: [ChatThread]
        var activeThreadId: UUID
    }

    enum Source: Equatable, Sendable {
        case current
        case unversioned
        case legacy
        case empty
        case quarantined(String)
        case writeProtected(String)
    }

    struct Restoration: Sendable {
        var snapshot: Snapshot?
        var source: Source
        var needsMigration: Bool
        var removeLegacyAfterSave: Bool
        var writesAllowed: Bool
    }

    /// The version is additive so backup/import code can keep reading the
    /// existing top-level `threads` and `activeThreadId` fields.
    private struct Archive: Codable, Sendable {
        var version: Int
        var threads: [ChatThread]
        var activeThreadId: UUID

        init(snapshot: Snapshot) {
            version = ChatThreadRepository.currentVersion
            threads = snapshot.threads
            activeThreadId = snapshot.activeThreadId
        }

        var snapshot: Snapshot {
            Snapshot(threads: threads, activeThreadId: activeThreadId)
        }
    }

    private struct UnversionedSnapshot: Codable {
        var threads: [ChatThread]
        var activeThreadId: UUID

        var snapshot: Snapshot {
            Snapshot(threads: threads, activeThreadId: activeThreadId)
        }
    }

    private struct LegacySnapshot: Codable {
        var messages: [ChatMessage]
        var editingContext: ChatSession.EditingContext?
    }

    private struct PendingWrite: Sendable {
        var snapshot: Snapshot
        var revision: UInt64
        var removeLegacyAfterSave: Bool
    }

    private enum ProtectedArchive: Sendable {
        case bytes(Data)
        case absent
        case unreadable
    }

    private let directory: URL
    private let archiveURL: URL
    private let legacyURL: URL
    private let store: AtomicFileStore<Archive>
    private let debounceNanoseconds: UInt64
    private var latestRevision: UInt64 = 0
    private var pendingWrite: PendingWrite?
    private var debounceTask: Task<Void, Never>?
    private var writesAllowed: Bool
    private var writeGeneration: UInt64 = 0
    private var writeInFlight = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var protectedArchive: ProtectedArchive?

    init(
        directory: URL? = nil,
        debounceNanoseconds: UInt64 = 150_000_000,
        initialWritesAllowed: Bool = true
    ) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = base
        archiveURL = base.appendingPathComponent("chat-threads.json")
        legacyURL = base.appendingPathComponent("chat-session.json")
        store = AtomicFileStore<Archive>(fileName: "chat-threads.json", directory: base)
        self.debounceNanoseconds = debounceNanoseconds
        writesAllowed = initialWritesAllowed
    }

    func restore() -> Restoration {
        let result = Self.restoreSynchronously(directory: directory)
        writesAllowed = result.writesAllowed
        return result
    }

    /// ChatSession must restore before its first SwiftUI render. This read-only
    /// entry point keeps that launch behavior; all encoding and writes remain
    /// actor-owned.
    nonisolated static func restoreSynchronously(directory: URL? = nil) -> Restoration {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let archiveURL = base.appendingPathComponent("chat-threads.json")
        let legacyURL = base.appendingPathComponent("chat-session.json")
        let decoder = JSONDecoder()

        if FileManager.default.fileExists(atPath: archiveURL.path) {
            do {
                let data = try Data(contentsOf: archiveURL)
                if data.count > 1 {
                    if let archive = try? decoder.decode(Archive.self, from: data) {
                        guard archive.version <= currentVersion else {
                            return Restoration(
                                snapshot: nil,
                                source: .writeProtected(archiveURL.lastPathComponent),
                                needsMigration: false,
                                removeLegacyAfterSave: false,
                                writesAllowed: false
                            )
                        }
                        return Restoration(
                            snapshot: archive.snapshot,
                            source: .current,
                            needsMigration: false,
                            removeLegacyAfterSave: false,
                            writesAllowed: true
                        )
                    }
                    if !declaresVersion(in: data),
                       let old = try? decoder.decode(UnversionedSnapshot.self, from: data) {
                        return Restoration(
                            snapshot: old.snapshot,
                            source: .unversioned,
                            needsMigration: true,
                            removeLegacyAfterSave: false,
                            writesAllowed: true
                        )
                    }
                    guard let quarantined = quarantine(data, at: archiveURL) else {
                        return Restoration(
                            snapshot: nil,
                            source: .writeProtected(archiveURL.lastPathComponent),
                            needsMigration: false,
                            removeLegacyAfterSave: false,
                            writesAllowed: false
                        )
                    }
                    return restoreLegacy(
                        at: legacyURL,
                        fallbackSource: .quarantined(quarantined.lastPathComponent)
                    )
                }
            } catch {
                return Restoration(
                    snapshot: nil,
                    source: .writeProtected(archiveURL.lastPathComponent),
                    needsMigration: false,
                    removeLegacyAfterSave: false,
                    writesAllowed: false
                )
            }
        }

        return restoreLegacy(at: legacyURL, fallbackSource: .empty)
    }

    /// Stops every queued write before re-reading a file replaced by backup
    /// import. If a save already crossed the actor boundary, preserve the
    /// replacement bytes and put them back before returning.
    func discardPendingWritesAndRestore(invalidatingThrough revision: UInt64) async -> Restoration {
        debounceTask?.cancel()
        debounceTask = nil
        pendingWrite = nil
        writeGeneration &+= 1
        latestRevision = max(latestRevision, revision)

        if writeInFlight {
            let archive = captureArchive()
            protectedArchive = archive
            let wasUnreadable: Bool
            if case .unreadable = archive { wasUnreadable = true } else { wasUnreadable = false }
            await waitForWriteToFinish()
            if protectedArchive != nil {
                do {
                    try await restoreProtectedArchive()
                } catch {
                    writesAllowed = false
                    return Restoration(
                        snapshot: nil,
                        source: .writeProtected(archiveURL.lastPathComponent),
                        needsMigration: false,
                        removeLegacyAfterSave: false,
                        writesAllowed: false
                    )
                }
            }
            if wasUnreadable {
                writesAllowed = false
                protectedArchive = nil
                return Restoration(
                    snapshot: nil,
                    source: .writeProtected(archiveURL.lastPathComponent),
                    needsMigration: false,
                    removeLegacyAfterSave: false,
                    writesAllowed: false
                )
            }
        }

        let result = Self.restoreSynchronously(directory: directory)
        writesAllowed = result.writesAllowed
        return result
    }

    func enqueue(
        _ snapshot: Snapshot,
        revision: UInt64,
        removeLegacyAfterSave: Bool = false
    ) {
        guard writesAllowed, revision > latestRevision else { return }
        latestRevision = revision
        let mustRemoveLegacy = removeLegacyAfterSave
            || (pendingWrite?.removeLegacyAfterSave ?? false)
        pendingWrite = PendingWrite(
            snapshot: snapshot,
            revision: revision,
            removeLegacyAfterSave: mustRemoveLegacy
        )
        debounceTask?.cancel()
        let delay = debounceNanoseconds
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            try? await self?.commitPendingWrite()
        }
    }

    /// Forces the newest queued snapshot to disk. Background/termination paths
    /// call this after awaiting their latest enqueue task.
    func flush() async throws {
        debounceTask?.cancel()
        debounceTask = nil
        try await commitPendingWrite()
    }

    nonisolated static func encode(_ snapshot: Snapshot) throws -> Data {
        try JSONEncoder().encode(Archive(snapshot: snapshot))
    }

    nonisolated static func mediaIds(inArchive data: Data) -> Set<String>? {
        let decoder = JSONDecoder()
        let snapshot: Snapshot?
        if let archive = try? decoder.decode(Archive.self, from: data),
           archive.version <= currentVersion {
            snapshot = archive.snapshot
        } else if !declaresVersion(in: data),
            let old = try? decoder.decode(UnversionedSnapshot.self, from: data) {
            snapshot = old.snapshot
        } else {
            snapshot = nil
        }
        guard let snapshot else { return nil }
        return Set(snapshot.threads.flatMap(\.messages).flatMap(\.mediaIds))
    }

    nonisolated private static func declaresVersion(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return false }
        return dictionary.keys.contains("version")
    }

    private func commitPendingWrite() async throws {
        while writeInFlight { await waitForWriteToFinish() }
        guard writesAllowed, let candidate = pendingWrite else { return }
        let generation = writeGeneration
        writeInFlight = true
        do {
            try await store.save(Archive(snapshot: candidate.snapshot))
            if generation != writeGeneration {
                try await restoreProtectedArchive()
            } else {
                if candidate.removeLegacyAfterSave {
                    try? FileManager.default.removeItem(at: legacyURL)
                }
                if pendingWrite?.revision == candidate.revision {
                    pendingWrite = nil
                }
            }
            finishWrite()
        } catch {
            if generation != writeGeneration {
                try? await restoreProtectedArchive()
            }
            finishWrite()
            throw error
        }
    }

    private func captureArchive() -> ProtectedArchive {
        do {
            return .bytes(try Data(contentsOf: archiveURL))
        } catch {
            return FileManager.default.fileExists(atPath: archiveURL.path)
                ? .unreadable
                : .absent
        }
    }

    private func restoreProtectedArchive() async throws {
        guard let protectedArchive else { return }
        switch protectedArchive {
        case .bytes(let data):
            try await store.restoreRaw(data)
        case .absent:
            try await store.delete()
        case .unreadable:
            writesAllowed = false
        }
        self.protectedArchive = nil
    }

    private func waitForWriteToFinish() async {
        guard writeInFlight else { return }
        await withCheckedContinuation { continuation in
            writeWaiters.append(continuation)
        }
    }

    private func finishWrite() {
        writeInFlight = false
        let waiters = writeWaiters
        writeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    nonisolated private static func restoreLegacy(
        at legacyURL: URL,
        fallbackSource: Source
    ) -> Restoration {
        if let data = try? Data(contentsOf: legacyURL),
           let legacy = try? JSONDecoder().decode(LegacySnapshot.self, from: data),
           !legacy.messages.isEmpty {
            var thread = ChatThread(
                messages: legacy.messages,
                editingContext: legacy.editingContext
            )
            if let firstUser = legacy.messages.first(where: { $0.role == .user }) {
                thread.title = String(firstUser.text.prefix(48))
            }
            return Restoration(
                snapshot: Snapshot(threads: [thread], activeThreadId: thread.id),
                source: .legacy,
                needsMigration: true,
                removeLegacyAfterSave: true,
                writesAllowed: true
            )
        }
        return Restoration(
            snapshot: nil,
            source: fallbackSource,
            needsMigration: false,
            removeLegacyAfterSave: false,
            writesAllowed: true
        )
    }

    nonisolated private static func quarantine(_ data: Data, at url: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent()
            .appendingPathComponent(
                "\(url.lastPathComponent).corrupt-\(stamp)-\(UUID().uuidString)"
            )
        do {
            try data.write(to: target, options: .atomic)
            try FileManager.default.removeItem(at: url)
            return target
        } catch {
            return nil
        }
    }
}
