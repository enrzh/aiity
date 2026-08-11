import XCTest
@testable import AIApp

final class ChatThreadRepositoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-repository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func repository(debounceNanoseconds: UInt64 = 1_000_000) -> ChatThreadRepository {
        ChatThreadRepository(directory: directory, debounceNanoseconds: debounceNanoseconds)
    }

    private func thread(_ text: String, mediaIds: [String] = []) -> ChatThread {
        ChatThread(messages: [
            ChatMessage(role: .user, text: text, mediaIds: mediaIds),
        ])
    }

    private func snapshot(_ text: String) -> ChatThreadRepository.Snapshot {
        let value = thread(text)
        return ChatThreadRepository.Snapshot(threads: [value], activeThreadId: value.id)
    }

    func testCurrentUnversionedSnapshotLoadsAndMigratesWithoutChangingItsShape() async throws {
        struct Unversioned: Codable {
            var threads: [ChatThread]
            var activeThreadId: UUID
        }

        let value = snapshot("bestehender Verlauf")
        let old = Unversioned(threads: value.threads, activeThreadId: value.activeThreadId)
        try JSONEncoder().encode(old).write(
            to: directory.appendingPathComponent("chat-threads.json"), options: .atomic
        )

        let repo = repository()
        let restored = await repo.restore()
        XCTAssertEqual(restored.snapshot, value)
        XCTAssertEqual(restored.source, .unversioned)
        XCTAssertTrue(restored.needsMigration)
        XCTAssertTrue(restored.writesAllowed)

        await repo.enqueue(value, revision: 1)
        try await repo.flush()

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("chat-threads.json"))
            ) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, ChatThreadRepository.currentVersion)
        XCTAssertNotNil(object["threads"], "versioning must not break backup/import's top-level threads shape")
    }

    func testLegacySingleSessionMigratesBeforeItsSourceIsRemoved() async throws {
        struct Legacy: Codable {
            var messages: [ChatMessage]
            var editingContext: ChatSession.EditingContext?
        }

        let legacyURL = directory.appendingPathComponent("chat-session.json")
        let legacy = Legacy(
            messages: [ChatMessage(role: .user, text: "alte Unterhaltung")],
            editingContext: nil
        )
        try JSONEncoder().encode(legacy).write(to: legacyURL, options: .atomic)

        let repo = repository()
        let restored = await repo.restore()
        XCTAssertEqual(restored.source, .legacy)
        XCTAssertEqual(restored.snapshot?.threads.first?.messages, legacy.messages)
        XCTAssertTrue(restored.removeLegacyAfterSave)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        let value = try XCTUnwrap(restored.snapshot)
        await repo.enqueue(value, revision: 1, removeLegacyAfterSave: true)
        try await repo.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let roundTrip = await repository().restore()
        XCTAssertEqual(roundTrip.source, .current)
        XCTAssertEqual(roundTrip.snapshot, value)
    }

    func testCorruptArchiveIsQuarantinedAndNeverOverwritten() async throws {
        let archiveURL = directory.appendingPathComponent("chat-threads.json")
        let original = Data("not-json-user-history".utf8)
        try original.write(to: archiveURL)

        let repo = repository()
        let restored = await repo.restore()
        guard case .quarantined = restored.source else {
            return XCTFail("expected quarantine, got \(restored.source)")
        }
        XCTAssertNil(restored.snapshot)
        XCTAssertTrue(restored.writesAllowed)

        let quarantine = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.contains("chat-threads.json.corrupt-") }
        )
        XCTAssertEqual(try Data(contentsOf: quarantine), original)

        await repo.enqueue(snapshot("neu"), revision: 1)
        try await repo.flush()
        XCTAssertEqual(try Data(contentsOf: quarantine), original, "recovery must preserve the bad bytes")
    }

    func testFutureArchiveVersionIsPreservedAndWriteProtected() async throws {
        let value = snapshot("aus einer neueren App")
        let encoded = try ChatThreadRepository.encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = ChatThreadRepository.currentVersion + 1
        let futureData = try JSONSerialization.data(withJSONObject: object)
        let archiveURL = directory.appendingPathComponent("chat-threads.json")
        try futureData.write(to: archiveURL)

        let repo = repository()
        let restored = await repo.restore()
        guard case .writeProtected = restored.source else {
            return XCTFail("future data must be write-protected")
        }
        XCTAssertFalse(restored.writesAllowed)
        XCTAssertNil(restored.snapshot)

        await repo.enqueue(snapshot("darf nicht schreiben"), revision: 1)
        try await repo.flush()
        XCTAssertEqual(try Data(contentsOf: archiveURL), futureData)
    }

    func testMalformedVersionIsQuarantinedInsteadOfDecodedAsUnversioned() async throws {
        let value = snapshot("ungueltige Version")
        let encoded = try ChatThreadRepository.encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = "one"
        let malformed = try JSONSerialization.data(withJSONObject: object)
        let archiveURL = directory.appendingPathComponent("chat-threads.json")
        try malformed.write(to: archiveURL)

        let restored = await repository().restore()

        guard case .quarantined = restored.source else {
            return XCTFail("a present but malformed version must not masquerade as unversioned")
        }
        let quarantine = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.contains("chat-threads.json.corrupt-") }
        )
        XCTAssertEqual(try Data(contentsOf: quarantine), malformed)
    }

    func testOlderRevisionCannotOverwriteNewerSnapshot() async throws {
        let repo = repository(debounceNanoseconds: 50_000_000)
        let newer = snapshot("neu")
        let older = snapshot("alt")

        await repo.enqueue(newer, revision: 2)
        await repo.enqueue(older, revision: 1)
        try await repo.flush()

        let restored = await repository().restore()
        XCTAssertEqual(restored.snapshot, newer)
    }

    func testDebouncedWritesPersistOnlyTheNewestRevision() async throws {
        let repo = repository(debounceNanoseconds: 100_000_000)
        for revision in 1...20 {
            await repo.enqueue(snapshot("v\(revision)"), revision: UInt64(revision))
        }
        try await repo.flush()

        let restored = await repository().restore()
        XCTAssertEqual(restored.snapshot?.threads.first?.messages.first?.text, "v20")
    }

    func testReloadRejectsEveryStaleDispatchFromBeforeTheImport() async throws {
        let repo = repository(debounceNanoseconds: 60_000_000_000)
        await repo.enqueue(snapshot("queued before import"), revision: 2)

        let imported = snapshot("imported archive")
        try ChatThreadRepository.encode(imported).write(
            to: directory.appendingPathComponent("chat-threads.json"),
            options: .atomic
        )

        let restored = await repo.discardPendingWritesAndRestore(invalidatingThrough: 4)
        XCTAssertEqual(restored.snapshot, imported)

        await repo.enqueue(snapshot("late stale dispatch"), revision: 3)
        try await repo.flush()
        let afterStaleDispatch = await repository().restore()
        XCTAssertEqual(afterStaleDispatch.snapshot, imported)

        let current = snapshot("new state after import")
        await repo.enqueue(current, revision: 5)
        try await repo.flush()
        let afterCurrentDispatch = await repository().restore()
        XCTAssertEqual(afterCurrentDispatch.snapshot, current)
    }

    func testExplicitFlushMakesPendingWriteImmediatelyVisible() async throws {
        let repo = repository(debounceNanoseconds: 60_000_000_000)
        let value = snapshot("flush")
        await repo.enqueue(value, revision: 1)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("chat-threads.json").path
        ))
        try await repo.flush()

        let restored = await repository().restore()
        XCTAssertEqual(restored.snapshot, value)
    }

    func testEnqueueAndFlushDurablyCommitsRequestedRevisionBeforeReturning() async throws {
        let repo = repository(debounceNanoseconds: 60_000_000_000)
        let value = snapshot("barrier")

        try await repo.enqueueAndFlush(value, revision: 7)

        let restored = await repository().restore()
        XCTAssertEqual(restored.snapshot, value)
    }

    func testPersistedMediaIdsSupportsVersionedAndUnversionedArchives() throws {
        let value = ChatThreadRepository.Snapshot(
            threads: [thread("media", mediaIds: ["a.png", "b.mov"])],
            activeThreadId: UUID()
        )
        let versioned = try ChatThreadRepository.encode(value)
        XCTAssertEqual(ChatThreadRepository.mediaIds(inArchive: versioned), ["a.png", "b.mov"])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: versioned) as? [String: Any])
        var unversioned = object
        unversioned.removeValue(forKey: "version")
        let oldData = try JSONSerialization.data(withJSONObject: unversioned)
        XCTAssertEqual(ChatThreadRepository.mediaIds(inArchive: oldData), ["a.png", "b.mov"])
    }

    func testPersistedMediaIdsIncludesAttachmentMediaIds() throws {
        let attachmentMediaId = UUID().uuidString
        let message = ChatMessage(
            role: .user,
            text: "attachment",
            attachments: [ChatAttachment(
                mediaId: attachmentMediaId,
                filename: "photo.png",
                mimeType: "image/png",
                kind: .image
            )]
        )
        let thread = ChatThread(messages: [message])
        let snapshot = ChatThreadRepository.Snapshot(
            threads: [thread],
            activeThreadId: thread.id
        )

        XCTAssertEqual(
            ChatThreadRepository.mediaIds(inArchive: try ChatThreadRepository.encode(snapshot)),
            [attachmentMediaId]
        )
    }

    func testPersistedMediaIdsReturnsNilForUnreadableDataNeverEmpty() {
        XCTAssertNil(ChatThreadRepository.mediaIds(inArchive: Data("garbage".utf8)))
        XCTAssertNil(ChatThreadRepository.mediaIds(inArchive: Data()))
    }

    @MainActor
    func testChatSessionPublicPersistenceSurvivesRelaunch() async throws {
        var session: ChatSession? = ChatSession(chatDirectory: directory)
        session?.messages = [
            ChatMessage(role: .user, text: "bleibt erhalten", mediaIds: ["photo.png"]),
        ]
        session?.persistPublic()
        await session?.flushPersistence()
        session = nil

        let relaunched = ChatSession(chatDirectory: directory)
        XCTAssertEqual(relaunched.messages.last?.text, "bleibt erhalten")
        XCTAssertEqual(relaunched.messages.last?.mediaIds, ["photo.png"])
    }

    @MainActor
    func testReloadDiscardsPendingStaleWriteBeforeApplyingImportedArchive() async throws {
        let session = ChatSession(chatDirectory: directory)
        session.messages = [ChatMessage(role: .user, text: "stale in memory")]
        session.persistPublic()

        let imported = snapshot("imported archive")
        try ChatThreadRepository.encode(imported).write(
            to: directory.appendingPathComponent("chat-threads.json"),
            options: .atomic
        )

        try await session.reloadFromDisk()

        XCTAssertEqual(session.messages.first?.text, "imported archive")
        await session.flushPersistence()

        let disk = await repository().restore()
        XCTAssertEqual(session.messages.first?.text, "imported archive")
        XCTAssertEqual(disk.snapshot?.activeThreadId, imported.activeThreadId)
        XCTAssertEqual(disk.snapshot?.threads.first?.id, imported.threads.first?.id)
        XCTAssertEqual(
            disk.snapshot?.threads.first?.messages,
            imported.threads.first?.messages,
            "a pre-import debounce must never overwrite the imported messages"
        )
    }

    @MainActor
    func testReloadStateRejectsNewThreadsAndGeneration() {
        let session = ChatSession(chatDirectory: directory)
        let originalThread = session.activeThreadIdForTesting
        session.setPersistenceReloadInProgressForTesting(true)

        XCTAssertNil(session.newThread())
        session.send("must not start", settings: ProviderSettings())

        XCTAssertEqual(session.activeThreadIdForTesting, originalThread)
        XCTAssertTrue(session.messages.isEmpty)
        XCTAssertFalse(session.busy)
    }

    @MainActor
    func testSuccessfulReloadClearsWriteProtectionAndResynchronizesRepository() async throws {
        let future = snapshot("future")
        let encoded = try ChatThreadRepository.encode(future)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = ChatThreadRepository.currentVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(
            to: directory.appendingPathComponent("chat-threads.json")
        )

        let session = ChatSession(chatDirectory: directory)
        XCTAssertNotNil(session.persistDisabledReason)

        let recovered = snapshot("recovered")
        try ChatThreadRepository.encode(recovered).write(
            to: directory.appendingPathComponent("chat-threads.json"),
            options: .atomic
        )
        try await session.reloadFromDisk()
        await session.flushPersistence()

        XCTAssertNil(session.persistDisabledReason)
        XCTAssertEqual(session.messages.first?.text, "recovered")

        session.messages = [ChatMessage(role: .user, text: "writes work again")]
        session.persistPublic()
        await session.flushPersistence()
        let disk = await repository().restore()
        XCTAssertEqual(disk.snapshot?.threads.first?.messages.first?.text, "writes work again")
    }
}
