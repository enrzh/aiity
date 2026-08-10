import XCTest
@testable import AIApp

// MARK: - Reading the model id

/// The footprint has to come out of the id, because the only other source —
/// `sizeHint` — is a hand-typed DOWNLOAD size and was wrong by design.
final class LocalModelIdParsingTests: XCTestCase {

    /// `nil` (not measurable) is a distinct outcome from any number, so it must
    /// never quietly compare equal to one.
    private func parameters(_ modelId: String) -> Double {
        LocalModelFootprint.parameters(inModelId: modelId) ?? -1
    }

    func testParameterCountsComeOutOfTheId() {
        let cases: [(String, Double)] = [
            ("mlx-community/Qwen2.5-0.5B-Instruct-4bit", 0.5),
            ("mlx-community/Llama-3.2-1B-Instruct-4bit", 1),
            ("mlx-community/gemma-3-1b-it-4bit", 1),
            ("mlx-community/Qwen2.5-1.5B-Instruct-4bit", 1.5),
            ("mlx-community/SmolLM2-1.7B-Instruct-4bit", 1.7),
            ("mlx-community/gemma-2-2b-it-4bit", 2),
            ("mlx-community/Llama-3.2-3B-Instruct-4bit", 3),
            ("mlx-community/Qwen3-4B-Instruct-2507-4bit", 4),
            ("mlx-community/deepseek-coder-6.7b-instruct-4bit", 6.7),
            ("mlx-community/Mistral-7B-Instruct-v0.3-4bit", 7),
            ("mlx-community/Qwen3-8B-4bit", 8),
            ("mlx-community/gemma-2-9b-it-4bit", 9),
            ("mlx-community/Qwen2.5-14B-Instruct-4bit", 14),
            ("mlx-community/Qwen2.5-32B-Instruct-4bit", 32),
            ("mlx-community/Llama-3.3-70B-Instruct-4bit", 70),
        ]
        for (id, expected) in cases {
            XCTAssertEqual(parameters(id), expected, accuracy: 0.001, id)
        }
    }

    /// The underscore spelling and an id whose own name ends in digits.
    func testTheAwkwardSpellingsInThisCatalogParse() {
        XCTAssertEqual(parameters("mlx-community/stablelm-2-zephyr-1_6b-4bit"), 1.6, accuracy: 0.001)
        XCTAssertEqual(parameters("mlx-community/internlm2_5-7b-chat-4bit"), 7, accuracy: 0.001,
                       "internlm2_5 must not be read as a size")
    }

    /// A release date and a context length are not parameter counts. A looser
    /// rule read `…-2407-4bit` as a 2407-billion-parameter model, which blocks
    /// a perfectly runnable 12B — the opposite failure, but still a failure.
    func testNumbersThatAreNotSizesAreNotReadAsSizes() {
        XCTAssertEqual(parameters("mlx-community/Mistral-Nemo-Instruct-2407-4bit"), 12.2, accuracy: 0.001,
                       "falls back to the published size of the family, not to 2407")
        XCTAssertEqual(parameters("mlx-community/Phi-3-mini-4k-instruct-4bit"), 3.8, accuracy: 0.001,
                       "4k is a context length")
        XCTAssertEqual(parameters("mlx-community/Phi-4-mini-instruct-4bit"), 3.8, accuracy: 0.001)
    }

    func testQuantisationComesOutOfTheId() {
        XCTAssertEqual(LocalModelFootprint.quantisationBits(inModelId: "x/Qwen3-8B-4bit"), 4)
        XCTAssertEqual(LocalModelFootprint.quantisationBits(inModelId: "x/Meta-Llama-3.1-8B-Instruct-8bit"), 8)
        XCTAssertEqual(
            LocalModelFootprint.quantisationBits(inModelId: "x/Some-7B-Instruct"), 16,
            "no marker means full precision — the pessimistic reading, on purpose"
        )
    }

    /// An unmeasurable id is allowed to exist (a user's own MLX repo id), and
    /// the gate lets it through — but nothing WE ship may be unmeasurable, or
    /// the gate silently stops applying to the catalog.
    func testEveryModelThisAppShipsIsMeasurable() {
        for model in LocalModel.allCandidates {
            XCTAssertNotNil(
                LocalModelFootprint.estimate(modelId: model.id),
                "\(model.id) has no inferable size — the gate would wave it through"
            )
        }
    }
}

// MARK: - The formula

final class LocalModelFootprintTests: XCTestCase {

    private func gb(_ value: Double) -> Int64 { Int64(value * 1_073_741_824) }

    /// The whole point: `sizeHint` is what the old catalog reasoned with, and
    /// it is far below what the model actually costs once the KV cache and the
    /// runtime exist.
    func testTheEstimateIsWellAboveTheDownloadSize() {
        // "2.3 GB" in the catalog.
        guard let estimate = LocalModelFootprint.estimate(
            modelId: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        ) else { return XCTFail("the default model must be measurable") }
        XCTAssertGreaterThan(
            estimate.peakBytes, gb(3.0),
            "a 2.3 GB download does not mean 2.3 GB of memory"
        )
        XCTAssertGreaterThan(estimate.kvCacheBytes, gb(0.5),
                             "the KV cache is the term sizeHint omits entirely")
    }

    /// Calibration anchor. A device report caught this model at 2822 MB with
    /// 554 MB left before the kill — a real ceiling of ~3376 MB. An estimator
    /// that put it below that would have permitted the run that died.
    func testTheDefaultModelIsEstimatedAboveTheFootprintThatGotKilled() {
        guard let peak = LocalModelFootprint.peakBytes(
            modelId: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        ) else { return XCTFail("unmeasurable") }
        XCTAssertGreaterThan(peak, 2822 * 1_048_576)
        XCTAssertLessThan(peak, gb(4.5), "…but not so pessimistic that nothing runs")
    }

    /// Weights scale with the quantisation, and the estimate must notice.
    func testEightBitCostsAboutTwiceAsMuchAsFourBit() {
        guard let four = LocalModelFootprint.estimate(modelId: "x/Meta-Llama-3.1-8B-Instruct-4bit"),
              let eight = LocalModelFootprint.estimate(modelId: "x/Meta-Llama-3.1-8B-Instruct-8bit") else {
            return XCTFail("unmeasurable")
        }
        let ratio = Double(eight.weightBytes) / Double(four.weightBytes)
        XCTAssertEqual(ratio, 8.5 / 4.5, accuracy: 0.01)
    }

    /// The context the estimate plans for is the one the app actually sends —
    /// if the transcript budget or the generation cap grows, the KV term must
    /// grow with it rather than silently going stale.
    func testThePlannedContextCoversWhatTheAppActuallySends() {
        XCTAssertGreaterThan(
            LocalModelFootprint.plannedContextTokens,
            LocalRuntimePolicy.maxTokens,
            "the generated tokens alone are in the cache"
        )
        // ~3.5 characters per token of German, plus the system prompt.
        let historyTokens = LocalRuntimePolicy.localTranscriptBudget / 4
        XCTAssertGreaterThanOrEqual(
            LocalModelFootprint.plannedContextTokens,
            LocalRuntimePolicy.maxTokens + historyTokens
        )
    }
}

// MARK: - The gate, as a table

/// A pure function of (model, device RAM, entitlement). It has to be, because
/// the SIMULATOR REPORTS THE HOST MAC'S MEMORY: a simulated iPhone 16 Pro says
/// it has however much this Mac has, so nothing measured here reproduces a real
/// device budget. Every value below is injected; only a physical device can
/// confirm that the fractions in `DeviceMemoryBudget` are calibrated right.
final class LocalModelGateTests: XCTestCase {

    private static let gib: Int64 = 1_073_741_824
    private func ram(_ gigabytes: Int64) -> Int64 { gigabytes * Self.gib }

    private func allowed(_ modelId: String, ram gigabytes: Int64, entitled: Bool) -> Bool {
        LocalModelGate.isAllowed(
            modelId: modelId,
            budgetBytes: DeviceMemoryBudget.staticBudgetBytes(
                physicalMemoryBytes: ram(gigabytes), increasedLimit: entitled
            )
        )
    }

    private static let tiny = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    private static let default4B = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    private static let seven = "mlx-community/Mistral-7B-Instruct-v0.3-4bit"
    private static let fourteen = "mlx-community/Qwen2.5-14B-Instruct-4bit"
    private static let thirtyTwo = "mlx-community/Qwen2.5-32B-Instruct-4bit"
    private static let seventy = "mlx-community/Llama-3.3-70B-Instruct-4bit"

    /// Every iPhone RAM size in scope. 4 GB (SE 3 / 13 / 14), 6 GB (15 / 16 /
    /// 16e / 14 Pro), 8 GB (15 Pro / 16 Pro / 17), 12 GB (17 Pro / Pro Max).
    private static let supportedRAMs: [Int64] = [4, 6, 8, 12]

    func testTheSmallestModelRunsOnTheSmallestSupportedPhone() {
        XCTAssertTrue(allowed(Self.tiny, ram: 4, entitled: false))
        XCTAssertTrue(allowed(Self.tiny, ram: 4, entitled: true))
    }

    /// The honest answer, pinned: a 4-bit 7B is ~3.7 GiB of weights and another
    /// ~0.9 GiB of KV cache at this app's context. An 8 GB iPhone gives an app
    /// roughly 5 GiB even with the increased-memory-limit entitlement, and that
    /// 5 GiB is shared with the chat UI and any open mini-app web view. It does
    /// not fit. It fits on a 12 GB iPhone 17 Pro, and only there.
    func testSevenBillionDoesNotFitOnAnEightGigabytePhone() {
        XCTAssertFalse(allowed(Self.seven, ram: 8, entitled: true),
                       "this is the size class people assume works and it does not")
        XCTAssertFalse(allowed(Self.seven, ram: 8, entitled: false))
        XCTAssertTrue(allowed(Self.seven, ram: 12, entitled: true))
    }

    /// The models the old catalog offered to every phone.
    func testTheHugeModelsAreBlockedOnEverySupportedIPhone() {
        for gigabytes in Self.supportedRAMs {
            for entitled in [false, true] {
                for model in [Self.fourteen, Self.thirtyTwo, Self.seventy] {
                    XCTAssertFalse(
                        allowed(model, ram: gigabytes, entitled: entitled),
                        "\(model) must never be allowed — \(gigabytes) GB, entitlement \(entitled)"
                    )
                }
            }
        }
    }

    /// This pair is the entitlement's entire justification: without it, the
    /// app's OWN DEFAULT local model does not fit on any iPhone that exists.
    func testTheEntitlementIsWhatMakesTheDefaultModelRunnable() {
        XCTAssertFalse(allowed(Self.default4B, ram: 6, entitled: false))
        XCTAssertFalse(allowed(Self.default4B, ram: 8, entitled: false),
                       "an 8 GB iPhone 16 Pro — the device that crashed")
        XCTAssertTrue(allowed(Self.default4B, ram: 6, entitled: true))
        XCTAssertTrue(allowed(Self.default4B, ram: 8, entitled: true))
    }

    /// More RAM never takes a model away.
    func testTheGateIsMonotonicInDeviceMemory() {
        for model in LocalModel.allCandidates.map(\.id) {
            var previouslyAllowed = false
            for gigabytes in Self.supportedRAMs {
                let now = allowed(model, ram: gigabytes, entitled: true)
                XCTAssertTrue(now || !previouslyAllowed,
                              "\(model) became unavailable on a bigger phone")
                previouslyAllowed = previouslyAllowed || now
            }
        }
    }

    /// What cannot be measured is not blocked — a user pointing MLX at their
    /// own repo id must not be stopped by a rule that has no opinion.
    func testAnUnmeasurableIdIsNotBlocked() {
        XCTAssertEqual(
            LocalModelGate.verdict(modelId: "someone/private-weights", budgetBytes: 1),
            .unknown
        )
        XCTAssertTrue(LocalModelGate.isAllowed(modelId: "someone/private-weights", budgetBytes: 1))
    }

    /// `physicalMemory` is the device total, not the app's allowance, and using
    /// it as the budget is the mistake that makes a gate useless.
    func testTheBudgetIsAFractionOfPhysicalMemoryAndNotPhysicalMemory() {
        for gigabytes in Self.supportedRAMs {
            for entitled in [false, true] {
                let budget = DeviceMemoryBudget.staticBudgetBytes(
                    physicalMemoryBytes: ram(gigabytes), increasedLimit: entitled
                )
                XCTAssertLessThan(budget, ram(gigabytes) * 7 / 10)
                XCTAssertGreaterThan(budget, ram(gigabytes) * 3 / 10)
            }
        }
    }

    /// The entitlement is assumed to buy nothing on a 4 GB phone: there is no
    /// spare RAM there to hand out, and assuming otherwise would unblock models
    /// on the very devices least able to take them.
    func testTheEntitlementChangesNothingOnASmallDevice() {
        XCTAssertEqual(
            DeviceMemoryBudget.staticBudgetBytes(physicalMemoryBytes: ram(4), increasedLimit: true),
            DeviceMemoryBudget.staticBudgetBytes(physicalMemoryBytes: ram(4), increasedLimit: false)
        )
        XCTAssertGreaterThan(
            DeviceMemoryBudget.staticBudgetBytes(physicalMemoryBytes: ram(8), increasedLimit: true),
            DeviceMemoryBudget.staticBudgetBytes(physicalMemoryBytes: ram(8), increasedLimit: false)
        )
    }

    func testTheShortageTextNamesAllThreeNumbers() {
        let text = LocalModelGate.shortageText(
            needBytes: 18 * Self.gib, budgetBytes: 5 * Self.gib, physicalMemoryBytes: 8 * Self.gib
        )
        XCTAssertTrue(text.contains("18"), text)
        XCTAssertTrue(text.contains("8 GB"), text)
        XCTAssertTrue(text.contains("5"), text)
    }
}

// MARK: - The catalog

final class LocalModelCatalogGateTests: XCTestCase {

    /// Nothing in the shipped catalog may be impossible everywhere. A row that
    /// no iPhone can run is a several-gigabyte invitation to a crash.
    func testTheCatalogOnlyOffersModelsSomeIPhoneCanRun() {
        for model in LocalModel.catalog {
            XCTAssertTrue(
                LocalModelGate.isAllowedOnAnySupportedDevice(modelId: model.id),
                "\(model.id) cannot run on any supported iPhone and must not be listed"
            )
        }
    }

    /// The specific entries the crashes came from.
    func testTheImpossibleModelsAreGoneFromTheCatalog() {
        let ids = Set(LocalModel.catalog.map(\.id))
        for gone in [
            "mlx-community/Llama-3.3-70B-Instruct-4bit",
            "mlx-community/Qwen2.5-32B-Instruct-4bit",
            "mlx-community/gemma-2-27b-it-4bit",
            "mlx-community/Qwen2.5-14B-Instruct-4bit",
            "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit",
            "mlx-community/Mistral-Nemo-Instruct-2407-4bit",
            "mlx-community/Meta-Llama-3.1-8B-Instruct-8bit",
        ] {
            XCTAssertFalse(ids.contains(gone), "\(gone) is still on offer")
        }
        XCTAssertLessThan(LocalModel.catalog.count, LocalModel.allCandidates.count)
        XCTAssertGreaterThan(LocalModel.catalog.count, 15, "the filter must not gut the catalog")
    }

    /// The default has to survive its own filter.
    func testTheDefaultModelIsStillOffered() {
        XCTAssertTrue(LocalModel.catalog.contains { $0.id == LocalModel.defaultId })
    }

    /// A model downloaded before the filter dropped it keeps a row, otherwise
    /// its gigabytes are stranded on the phone with no delete button.
    func testADroppedModelStillOnDiskKeepsARow() {
        let dropped = "mlx-community/Llama-3.3-70B-Instruct-4bit"
        let withoutIt = LocalModel.rows(downloadedIds: [])
        XCTAssertFalse(withoutIt.contains { $0.id == dropped })

        let withIt = LocalModel.rows(downloadedIds: [dropped])
        XCTAssertTrue(withIt.contains { $0.id == dropped },
                      "no row means no trash button means no way to free the space")
        XCTAssertEqual(withIt.count, withoutIt.count + 1)
    }
}

// MARK: - Load time

/// The second gate. A model choice is not only made on this phone: it arrives
/// through `CloudSettingsSync` from another device, and out of a restored
/// backup. Neither passes the picker.
final class LocalModelLoadGateTests: XCTestCase {

    private static let gib: Int64 = 1_073_741_824

    func testTheRuntimeRefusesAModelThatDoesNotFitTheLiveBudget() {
        XCTAssertThrowsError(
            try MLXRuntime.assertFits(
                modelId: "mlx-community/Llama-3.3-70B-Instruct-4bit",
                budgetBytes: 5 * Self.gib
            )
        ) { error in
            let message = (error as? ProviderError)?.localizedDescription ?? "\(error)"
            XCTAssertTrue(message.contains("Zu wenig Speicher"), message)
            XCTAssertTrue(message.contains("kleineres lokales Modell"), message)
        }
    }

    /// A model that fits must load exactly as before — the gate may not become
    /// a reason on-device inference stops working where it used to.
    func testTheRuntimeDoesNotRefuseAModelThatFits() {
        XCTAssertNoThrow(
            try MLXRuntime.assertFits(
                modelId: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                budgetBytes: 3 * Self.gib
            )
        )
    }

    /// The load gate is independent of the picker: it must refuse an id the
    /// picker would never have offered, because the picker never saw it.
    func testAnIdSyncedFromABiggerPhoneIsRefusedHere() {
        let fromABiggerPhone = "mlx-community/gemma-2-9b-it-4bit"
        XCTAssertTrue(
            LocalModel.catalog.contains { $0.id == fromABiggerPhone },
            "this is a legitimate choice on a 12 GB iPhone"
        )
        XCTAssertThrowsError(
            try MLXRuntime.assertFits(modelId: fromABiggerPhone, budgetBytes: 4 * Self.gib)
        )
    }

    /// `MemoryPressure` is the post-hoc release valve and stays one — the new
    /// gate must not have turned it into a second, weaker admission check.
    func testMemoryPressureStillOnlyReleases() {
        MemoryPressure.shared.reset()
        var released = 0
        MemoryPressure.shared.onPressure("test") { released += 1 }
        MemoryPressure.shared.note()
        XCTAssertEqual(released, 1)
        MemoryPressure.shared.reset()
    }
}

@MainActor
final class LocalModelDownloadGateTests: XCTestCase {

    /// Downloading a model that can never be loaded spends gigabytes of the
    /// user's data on an error message.
    func testDownloadingAnImpossibleModelIsRefusedBeforeAnyBytesMove() {
        let store = LocalModelStore.shared
        store.errorMessage = nil
        store.download("mlx-community/Llama-3.3-70B-Instruct-4bit")
        XCTAssertNil(
            store.progress["mlx-community/Llama-3.3-70B-Instruct-4bit"],
            "no download may have started"
        )
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.errorMessage?.contains("Zu wenig Speicher") == true, store.errorMessage ?? "")
        store.errorMessage = nil
    }
}

// MARK: - Entitlement

/// `DeviceMemoryBudget.hasIncreasedMemoryLimit` decides how much of the
/// device's RAM the catalog assumes it may use. If it says yes and the
/// entitlement is not actually in the bundle, the app offers models it will
/// then be killed for loading — the original bug, restated.
final class EntitlementsMirrorTests: XCTestCase {

    private func entitlements() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // AIAppTests/
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("AIApp/AIApp.entitlements")
        guard let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil
        ) as? [String: Any] else {
            throw XCTSkip("entitlements not readable from \(url.path)")
        }
        return plist
    }

    func testTheIncreasedMemoryLimitConstantMatchesTheEntitlementsFile() throws {
        let declared = (try entitlements()["com.apple.developer.kernel.increased-memory-limit"] as? Bool) ?? false
        XCTAssertEqual(
            declared, DeviceMemoryBudget.hasIncreasedMemoryLimit,
            "the memory budget assumes an entitlement the bundle does not carry (or the other way round)"
        )
    }

    /// Adding one entitlement must not have dropped another — CloudKit and KVS
    /// are silent failures when they go missing.
    func testTheExistingEntitlementsSurvived() throws {
        let plist = try entitlements()
        XCTAssertNotNil(plist["com.apple.developer.icloud-container-identifiers"])
        XCTAssertNotNil(plist["com.apple.developer.ubiquity-kvstore-identifier"])
        XCTAssertNotNil(plist["com.apple.developer.icloud-services"])
        XCTAssertNotNil(plist["aps-environment"])
    }
}
