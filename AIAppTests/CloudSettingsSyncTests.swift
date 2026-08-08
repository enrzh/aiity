import XCTest
@testable import AIApp

/// KVS never surfaces failures — a regression in this engine silently stops
/// settings sync with no error anywhere, which is exactly why it runs against
/// an injected fake here instead of the untestable real store.
final class CloudSettingsSyncTests: XCTestCase {

    private final class FakeCloudStore: CloudKeyValueStore {
        private(set) var storage: [String: Data] = [:]
        private(set) var setCount = 0

        func data(forKey aKey: String) -> Data? { storage[aKey] }

        func set(_ aData: Data?, forKey aKey: String) {
            setCount += 1
            storage[aKey] = aData
        }

        @discardableResult
        func synchronize() -> Bool { true }
    }

    private let suite = "cloud-settings-sync-tests"
    private var defaults: UserDefaults!
    private var store: FakeCloudStore!
    private var engine: CloudSettingsSync!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        store = FakeCloudStore()
        engine = CloudSettingsSync(store: store, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - Adoption

    func testAdoptCopiesRemoteOntoFreshDevice() {
        store.set(Data("remote".utf8), forKey: "k")
        var received: Data?
        engine.adopt(key: "k") { received = $0 }

        XCTAssertEqual(defaults.data(forKey: "k"), Data("remote".utf8))
        XCTAssertEqual(received, Data("remote".utf8))
    }

    func testAdoptNeverClobbersAnExistingLocalValue() {
        defaults.set(Data("local".utf8), forKey: "k")
        store.set(Data("remote".utf8), forKey: "k")
        var calls = 0
        engine.adopt(key: "k") { _ in calls += 1 }

        XCTAssertEqual(defaults.data(forKey: "k"), Data("local".utf8))
        XCTAssertEqual(calls, 0)
    }

    // MARK: - External changes

    func testExternalChangeUpdatesLocalAndFiresHandler() {
        defaults.set(Data("old".utf8), forKey: "k")
        var received: Data?
        engine.adopt(key: "k") { received = $0 }

        store.set(Data("new".utf8), forKey: "k")
        engine.applyExternalChanges(forKeys: ["k"])

        XCTAssertEqual(defaults.data(forKey: "k"), Data("new".utf8))
        XCTAssertEqual(received, Data("new".utf8))
    }

    /// The old registry bound the FIRST handler forever: a recreated owner
    /// (SwiftUI rebuilding a @StateObject) silently stopped receiving remote
    /// changes until relaunch.
    func testReAdoptingReplacesTheHandler() {
        store.set(Data("v1".utf8), forKey: "k")
        var firstCalls = 0
        var secondCalls = 0
        engine.adopt(key: "k") { _ in firstCalls += 1 }   // adopts v1 → 1 call
        engine.adopt(key: "k") { _ in secondCalls += 1 }  // local exists → no call

        store.set(Data("v2".utf8), forKey: "k")
        engine.applyExternalChanges(forKeys: ["k"])

        XCTAssertEqual(firstCalls, 1, "the replaced handler must not fire for later changes")
        XCTAssertEqual(secondCalls, 1, "the CURRENT handler receives the change")
    }

    func testIdenticalRemoteBlobChangesNothing() {
        defaults.set(Data("same".utf8), forKey: "k")
        store.set(Data("same".utf8), forKey: "k")
        var calls = 0
        engine.adopt(key: "k") { _ in calls += 1 }

        engine.applyExternalChanges(forKeys: ["k"])
        XCTAssertEqual(calls, 0, "an echo of our own push must not ripple into another save")
    }

    func testUnadoptedKeysAreIgnored() {
        store.set(Data("x".utf8), forKey: "other")
        engine.applyExternalChanges(forKeys: ["other"])
        XCTAssertNil(defaults.data(forKey: "other"))
    }

    // MARK: - Push

    func testPushMirrorsAndSkipsIdenticalBlob() {
        engine.push(key: "k", data: Data("a".utf8))
        XCTAssertEqual(store.data(forKey: "k"), Data("a".utf8))
        let count = store.setCount

        engine.push(key: "k", data: Data("a".utf8))
        XCTAssertEqual(store.setCount, count, "an identical blob is an echo, not a change")

        engine.push(key: "k", data: Data("b".utf8))
        XCTAssertEqual(store.setCount, count + 1)
        XCTAssertEqual(store.data(forKey: "k"), Data("b".utf8))
    }

    // MARK: - Per-provider profile merge (through the engine)

    private func profilesData(_ models: [String: String]) -> Data {
        var map: [String: ProviderProfile] = [:]
        for (presetId, model) in models {
            var profile = ProviderProfile()
            profile.model = model
            map[presetId] = profile
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(map)
    }

    private func decodeProfiles(_ data: Data?) -> [String: ProviderProfile] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: ProviderProfile].self, from: data)) ?? [:]
    }

    func testExternalProfilesChangeMergesPerProviderInsteadOfOverwriting() {
        let key = ProviderProfiles.storageKey
        defaults.set(profilesData(["openrouter": "gpt-lokal", "mlx": "qwen-3"]), forKey: key)
        store.set(profilesData(["openrouter": "", "anthropic": "claude-x"]), forKey: key)

        var received: Data?
        engine.adopt(key: key, merge: ProviderProfiles.mergedData) { received = $0 }
        engine.applyExternalChanges(forKeys: [key])

        let merged = decodeProfiles(defaults.data(forKey: key))
        XCTAssertEqual(merged["openrouter"]?.model, "gpt-lokal",
                       "a remote EMPTY model must never clobber a local explicit pick")
        XCTAssertEqual(merged["anthropic"]?.model, "claude-x",
                       "another device's explicit pick is adopted")
        XCTAssertEqual(merged["mlx"]?.model, "qwen-3",
                       "providers the remote map never configured stay known (union)")
        XCTAssertNotNil(received)
        XCTAssertEqual(store.data(forKey: key), defaults.data(forKey: key),
                       "the union is published back so every device converges")
    }

    // MARK: - Merge semantics (pure)

    func testProfileMergeRemoteExplicitPickWins() {
        var mine = ProviderProfile(); mine.model = "alt"
        var theirs = ProviderProfile(); theirs.model = "neu"
        let merged = ProviderProfiles.merged(local: ["p": mine], incoming: ["p": theirs])
        XCTAssertEqual(merged["p"]?.model, "neu")
    }

    func testProfileMergeNeverInventsAModel() {
        let merged = ProviderProfiles.merged(
            local: ["p": ProviderProfile()],
            incoming: ["p": ProviderProfile()]
        )
        XCTAssertEqual(merged["p"]?.model, "",
                       "empty on both sides is 'deliberately unchosen' and must stay that way")
    }

    func testProfileMergeKeepsLocalBaseURLWhenRemoteEmpty() {
        var mine = ProviderProfile(); mine.baseURL = "http://gateway.local"
        let merged = ProviderProfiles.merged(local: ["p": mine], incoming: ["p": ProviderProfile()])
        XCTAssertEqual(merged["p"]?.baseURL, "http://gateway.local")
    }

    func testSettingsMergeKeepsLocalModelForSameProvider() {
        var mine = ProviderSettings()
        mine.presetId = "openrouter"
        mine.model = "gpt-lokal"
        mine.baseURL = "http://gateway.local"
        var theirs = ProviderSettings()
        theirs.presetId = "openrouter"
        theirs.model = ""

        let merged = try! JSONDecoder().decode(
            ProviderSettings.self,
            from: ProviderSettings.mergedData(
                local: try! JSONEncoder().encode(mine),
                incoming: try! JSONEncoder().encode(theirs)
            )
        )
        XCTAssertEqual(merged.model, "gpt-lokal")
        XCTAssertEqual(merged.baseURL, "http://gateway.local")
    }

    func testSettingsMergeProviderSwitchWinsWholesale() {
        var mine = ProviderSettings()
        mine.presetId = "openrouter"
        mine.model = "gpt-lokal"
        var theirs = ProviderSettings()
        theirs.presetId = "anthropic"
        theirs.model = ""

        let merged = try! JSONDecoder().decode(
            ProviderSettings.self,
            from: ProviderSettings.mergedData(
                local: try! JSONEncoder().encode(mine),
                incoming: try! JSONEncoder().encode(theirs)
            )
        )
        XCTAssertEqual(merged.presetId, "anthropic")
        XCTAssertEqual(merged.model, "",
                       "filling a DIFFERENT provider's slot from local state would invent a choice")
    }

    func testSettingsMergeFallsBackToIncomingOnGarbage() {
        let incoming = Data("not json".utf8)
        XCTAssertEqual(ProviderSettings.mergedData(local: Data("x".utf8), incoming: incoming), incoming)
        XCTAssertEqual(ProviderProfiles.mergedData(local: Data("x".utf8), incoming: incoming), incoming)
    }
}
