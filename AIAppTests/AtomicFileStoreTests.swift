import XCTest
@testable import AIApp

/// The behaviours the rest of the persistence layer will depend on: a missing
/// file is not an error, unreadable bytes are kept rather than replaced, and a
/// failed write never damages what was already stored.
final class AtomicFileStoreTests: XCTestCase {
    private struct Payload: Codable, Equatable, Sendable {
        var items: [String]
        var version: Int
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atomic-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(_ name: String = "test.json") -> AtomicFileStore<Payload> {
        AtomicFileStore<Payload>(fileName: name, directory: directory)
    }

    func testRoundTrip() async throws {
        let store = makeStore()
        let payload = Payload(items: ["a", "b"], version: 3)
        try await store.save(payload)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, payload)
    }

    func testMissingFileIsAnEmptyStartNotAnError() async {
        let store = makeStore("never-written.json")
        do {
            _ = try await store.load()
            XCTFail("expected notFound")
        } catch let error as RepositoryError {
            XCTAssertEqual(error, .notFound)
            XCTAssertTrue(error.isEmptyStart)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testLoadOrEmptyReturnsFallbackWhenNothingStored() async throws {
        let store = makeStore("absent.json")
        let fallback = Payload(items: [], version: 1)
        let loaded = try await store.load(orEmpty: fallback)
        XCTAssertEqual(loaded, fallback)
    }

    // MARK: - Corruption

    /// The bytes must survive. Replacing them with an empty value is how a
    /// user's history disappears without anyone noticing.
    func testCorruptDataIsQuarantinedRatherThanOverwritten() async throws {
        let store = makeStore("corrupt.json")
        let path = directory.appendingPathComponent("corrupt.json")
        try Data("{ this is not valid json".utf8).write(to: path)

        do {
            _ = try await store.load()
            XCTFail("expected corrupt")
        } catch let error as RepositoryError {
            guard case .corrupt = error else { return XCTFail("wrong case: \(error)") }
            XCTAssertFalse(error.isEmptyStart, "corruption must not read as an empty start")
        }

        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".corrupt-") }
        XCTAssertEqual(quarantined.count, 1, "the unreadable bytes should be kept")

        let kept = try String(
            contentsOf: directory.appendingPathComponent(quarantined[0]),
            encoding: .utf8
        )
        XCTAssertTrue(kept.contains("not valid json"), "the original bytes must be preserved verbatim")
    }

    /// After quarantine the store is usable again — the next save must not
    /// append to or trip over the bad file.
    func testStoreIsWritableAgainAfterCorruption() async throws {
        let store = makeStore("recover.json")
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("recover.json"))
        _ = try? await store.load()

        let fresh = Payload(items: ["neu"], version: 1)
        try await store.save(fresh)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, fresh)
    }

    /// A zero-length file is a previous failed write, not content worth keeping.
    func testEmptyFileReadsAsEmptyStart() async {
        let store = makeStore("empty.json")
        try? Data().write(to: directory.appendingPathComponent("empty.json"))
        do {
            _ = try await store.load()
            XCTFail("expected notFound")
        } catch let error as RepositoryError {
            XCTAssertTrue(error.isEmptyStart)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Writes

    func testOverwritePreservesTheLatestValue() async throws {
        let store = makeStore("over.json")
        try await store.save(Payload(items: ["alt"], version: 1))
        try await store.save(Payload(items: ["neu", "neuer"], version: 2))
        let loaded = try await store.load()
        XCTAssertEqual(loaded.items, ["neu", "neuer"])
        XCTAssertEqual(loaded.version, 2)
    }

    func testDeletingAnAbsentFileSucceeds() async throws {
        let store = makeStore("gone.json")
        try await store.delete()   // must not throw
    }

    func testDeleteRemovesStoredValue() async throws {
        let store = makeStore("bye.json")
        try await store.save(Payload(items: ["x"], version: 1))
        try await store.delete()
        do {
            _ = try await store.load()
            XCTFail("expected notFound after delete")
        } catch let error as RepositoryError {
            XCTAssertTrue(error.isEmptyStart)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// Concurrent writers must not interleave into a corrupt file — the actor
    /// serialises them and the last value wins, intact.
    func testConcurrentSavesLeaveAValidFile() async throws {
        let store = makeStore("concurrent.json")
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try? await store.save(Payload(items: ["run-\(index)"], version: index))
                }
            }
        }
        let loaded = try await store.load()
        XCTAssertEqual(loaded.items.count, 1, "the file must be a whole value, not a mix")
    }
}
