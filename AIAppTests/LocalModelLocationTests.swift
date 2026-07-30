import XCTest
@testable import AIApp

/// Guards the "is this on-device model actually usable?" check. A real device
/// run failed here: an interrupted download left `config.json` behind, the app
/// reported the model as ready, and every generation then died with an opaque
/// network error while MLX tried to fetch the missing tensors.
final class LocalModelLocationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localmodel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, bytes: Int) throws {
        try Data(repeating: 0x41, count: bytes).write(to: root.appendingPathComponent(name))
    }

    func testConfigOnlyIsNotComplete() throws {
        try write("config.json", bytes: 120)
        XCTAssertFalse(LocalModelLocation.isComplete(directory: root),
                       "metadata without weights must not count as downloaded")
    }

    func testConfigPlusWeightsIsComplete() throws {
        try write("config.json", bytes: 120)
        try write("model.safetensors", bytes: 4096)
        XCTAssertTrue(LocalModelLocation.isComplete(directory: root))
    }

    func testZeroByteWeightPlaceholderIsNotComplete() throws {
        try write("config.json", bytes: 120)
        try write("model.safetensors", bytes: 0)
        XCTAssertFalse(LocalModelLocation.isComplete(directory: root),
                       "a killed download leaves an empty placeholder")
    }

    func testOneMissingShardIsNotComplete() throws {
        try write("config.json", bytes: 120)
        try write("model-00001-of-00002.safetensors", bytes: 4096)
        try write("model-00002-of-00002.safetensors", bytes: 0)
        XCTAssertFalse(LocalModelLocation.isComplete(directory: root),
                       "a sharded model needs every shard")
    }

    func testMissingDirectoryIsNotComplete() {
        XCTAssertFalse(LocalModelLocation.isComplete(
            directory: root.appendingPathComponent("does-not-exist", isDirectory: true)
        ))
    }
}
