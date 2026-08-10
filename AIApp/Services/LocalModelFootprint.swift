import Foundation
#if canImport(os)
import os
#endif

/// How much memory an on-device model really needs — computed from the model
/// id, never read off a hand-typed size string.
///
/// # Why this exists
///
/// Build 9 died five times in fourteen minutes on one iPhone 16 Pro and left no
/// crash payload at all. That is the signature of a jetsam kill: iOS ends the
/// process for exceeding its memory limit without producing a stack trace, so
/// every exported feedback bundle contained metadata and nothing else. The same
/// report ("crashing on setup of local llm") had already arrived on build 2.
///
/// The cause was the catalog: it offered 14B, 32B and 70B models to every
/// phone, gated by nothing but a sentence of prose in the row subtitle ("Sehr
/// groß — nur High-RAM Geräte"). A prose hint is not a gate. Neither is
/// `sizeHint`, which is the DOWNLOAD size — the weights on disk, before the KV
/// cache and the framework exist at all.
///
/// # The formula
///
///     peak = (weights + kvCache) × headroom + runtimeFloor
///
/// ## weights = `params × (bitsPerWeight + 0.5) / 8`
///
/// The `+ 0.5` bit per weight is quantisation metadata: MLX stores an fp16
/// scale and bias per group of 64 weights, and leaves embeddings, norms and the
/// LM head in higher precision. Checked against the published repository sizes
/// of the mlx-community models this catalog links to, the rule lands within
/// ~2 % for anything ≥ 3B (7B-4bit → 3.94 GB vs 4.0 GB listed, 8B-8bit → 8.5 GB
/// vs 8 GB, 32B-4bit → 18.0 GB vs 18 GB, 70B-4bit → 39.4 GB vs 40 GB). It
/// understates models ≤ 1.5B by up to a quarter, where the unquantised
/// embedding table dominates — which does not matter, because those fit on
/// every supported device by a wide margin.
///
/// ## kvCache = `4 bytes × kvWidth × layers × plannedContextTokens`
///
/// 4 bytes = 2 bytes per fp16 element × 2 tensors (K and V). This is the term
/// `sizeHint` completely omits, and it is not small: a 4B model at this app's
/// context is another 0.8 GB on top of 2.1 GB of weights.
///
/// `plannedContextTokens` is derived from what the app actually sends, not from
/// the model's maximum: `LocalRuntimePolicy.localTranscriptBudget` characters of
/// history + the system prompt and tool schemas + `LocalRuntimePolicy.maxTokens`
/// generated tokens. See `plannedContextTokens`.
///
/// `layers` and `kvWidth` are not in the model id, so they are estimated from
/// the parameter count by the standard depth-scaling relation (depth grows with
/// the cube root of parameters at a fixed aspect ratio), fitted to the
/// configurations of the models in this catalog. It is exact at 4B (35 vs 36
/// layers), 14B (49 vs 48) and 70B (80 vs 80), and conservative in the 7–8B
/// band (42 vs 32–36). Conservative is the correct direction for a safety gate.
///
/// ## headroom = 1.10
///
/// Transient activation buffers and Metal heap fragmentation, both of which
/// scale with the model rather than being constant.
///
/// ## runtimeFloor = 320 MB
///
/// The part that does not scale: the MLX/Metal runtime, the compiled shader
/// pipeline, the tokenizer, and the app's own SwiftUI + WebKit baseline, which
/// shares the same jetsam limit.
///
/// # Calibration
///
/// A device report (see `LocalRuntimePolicy.localTranscriptBudget`) caught a
/// group round on the 4-bit 4B default reaching 2822 MB with 554 MB of headroom
/// left — a real limit of ~3376 MB — before iOS killed it. This estimator puts
/// that model at 3.52 GiB, i.e. it predicts the kill, and predicts it on a
/// device whose measured limit was below that. That is the behaviour wanted:
/// slightly pessimistic, never optimistic.
///
/// Everything here is pure and static so the gate can be tested against a table
/// of (model, RAM, entitlement) without a device — see the note on the
/// simulator in `DeviceMemoryBudget`.
enum LocalModelFootprint {

    /// The context this app plans for, in tokens.
    ///
    /// `LocalRuntimePolicy.localTranscriptBudget` is 6 000 characters of
    /// history (~1 700 tokens of German), plus roughly 800 tokens of system
    /// prompt and tool schemas, plus `LocalRuntimePolicy.maxTokens` (3 072)
    /// generated tokens, all of which are in the KV cache at the end of a turn.
    /// Rounded up to the next power-of-two-ish figure.
    static let plannedContextTokens = 6_144

    /// Activation buffers and heap fragmentation — proportional to the model.
    static let headroomFactor = 1.10

    /// MLX + Metal + tokenizer + the app's own baseline, which shares the limit.
    static let runtimeFloorBytes: Int64 = 320 * 1024 * 1024

    /// Bits of quantisation metadata per weight (fp16 scale + bias per group).
    static let quantisationMetadataBits = 0.5

    // MARK: - Reading the model id

    /// Bits per weight, from the `-4bit` / `-8bit` suffix mlx-community uses.
    /// An id with no quantisation marker is fp16 — the honest default, and the
    /// pessimistic one.
    static func quantisationBits(inModelId modelId: String) -> Double {
        for token in tokens(of: modelId) {
            guard token.hasSuffix("bit") else { continue }
            let digits = token.dropLast(3)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber), let bits = Double(digits) {
                return bits
            }
        }
        return 16
    }

    /// Parameter count in billions, from the `NNB` token in the id.
    ///
    /// Handles the three spellings the catalog actually contains: `7B`, `0.5B`
    /// and `1_6b`. Tokens like `4bit`, `2507` (a date) and `4k` (a context
    /// length) deliberately do not match — an earlier, looser regex read
    /// `Mistral-Nemo-Instruct-2407-4bit` as a 2407-billion-parameter model.
    ///
    /// `nil` means "not inferable". That is not an error: see `LocalModelGate`,
    /// which never blocks what it cannot measure, and
    /// `LocalModelFootprintTests`, which asserts every catalog entry IS
    /// measurable so that door stays shut for the models we ship.
    static func parameters(inModelId modelId: String) -> Double? {
        var best: Double?
        for token in tokens(of: modelId) {
            guard token.hasSuffix("b") else { continue }
            let number = token.dropLast().replacingOccurrences(of: "_", with: ".")
            guard !number.isEmpty,
                  number.allSatisfy({ $0.isNumber || $0 == "." }),
                  number.first!.isNumber,
                  let value = Double(number) else { continue }
            best = max(best ?? 0, value)
        }
        if let best { return best }
        // Families that spell the size nowhere in the id.
        for (needle, billions) in familyParameterCounts where modelId.lowercased().contains(needle) {
            return billions
        }
        return nil
    }

    /// Only for ids that carry no size token at all. Values are the published
    /// parameter counts.
    private static let familyParameterCounts: [(needle: String, billions: Double)] = [
        ("mistral-nemo", 12.2),
        ("phi-4-mini", 3.8),
        ("phi-3.5-mini", 3.8),
        ("phi-3-mini", 3.8),
    ]

    private static func tokens(of modelId: String) -> [String] {
        modelId.lowercased().split(whereSeparator: { $0 == "-" || $0 == "/" }).map(String.init)
    }

    // MARK: - Geometry

    /// Transformer depth grows with the cube root of the parameter count at a
    /// fixed aspect ratio. Fitted to this catalog's configurations.
    static func estimatedLayers(parametersBillions: Double) -> Int {
        let raw = 18.0 * cbrt(max(parametersBillions, 0.01)) + 6.0
        return min(96, max(16, Int(raw.rounded())))
    }

    /// `kvHeads × headDim` — the width of one K (or V) vector per layer. The
    /// Llama/Qwen/Gemma families in this catalog use 8 KV heads × 128 dims once
    /// they are past ~2B; the smaller ones use narrower heads.
    static func estimatedKVWidth(parametersBillions: Double) -> Int {
        parametersBillions < 2 ? 512 : 1024
    }

    // MARK: - The estimate

    struct Estimate: Equatable {
        let modelId: String
        let parametersBillions: Double
        let bitsPerWeight: Double
        let weightBytes: Int64
        let kvCacheBytes: Int64

        var peakBytes: Int64 {
            Int64(Double(weightBytes + kvCacheBytes) * headroomFactor) + runtimeFloorBytes
        }
    }

    /// `nil` when the id carries no inferable parameter count.
    static func estimate(modelId: String) -> Estimate? {
        guard let parameters = parameters(inModelId: modelId) else { return nil }
        let bits = quantisationBits(inModelId: modelId)
        let weights = parameters * 1e9 * (bits + quantisationMetadataBits) / 8
        let kv = 4 * Int64(estimatedKVWidth(parametersBillions: parameters))
            * Int64(estimatedLayers(parametersBillions: parameters))
            * Int64(plannedContextTokens)
        return Estimate(
            modelId: modelId,
            parametersBillions: parameters,
            bitsPerWeight: bits,
            weightBytes: Int64(weights),
            kvCacheBytes: kv
        )
    }

    /// Peak estimate in bytes, or `nil` if the id is not measurable.
    static func peakBytes(modelId: String) -> Int64? {
        estimate(modelId: modelId)?.peakBytes
    }
}

/// What this device will actually let the app have — which is never
/// `ProcessInfo.processInfo.physicalMemory`.
///
/// # Two different budgets, on purpose
///
/// 1. **Catalog / picker** — `catalogBudgetBytes`, derived from
///    `physicalMemory`. It has to be stable: a row must not flicker between
///    available and blocked because a web view happened to be open. It answers
///    "can this phone ever run this model?".
/// 2. **Load** — `loadBudgetBytes()`, derived from `os_proc_available_memory()`,
///    which is the kernel's own answer to "how much more may this process
///    allocate right now", already accounting for the entitlement, the device,
///    the iOS version and everything the app is currently holding. It answers
///    "can this phone run this model *at this moment*?".
///
/// # The simulator cannot answer either question
///
/// A simulated iPhone runs as a macOS process and reports the HOST Mac's
/// memory: `physicalMemory` is the Mac's RAM and `os_proc_available_memory()`
/// is a macOS-sized figure. Nothing measured in the simulator says anything
/// about a real device budget. That is why every value here is injectable and
/// the gate itself is a pure function of (estimate, budget) — the tests pin the
/// arithmetic against a table of real device sizes, and only a physical device
/// can confirm the *calibration* of the fractions below.
enum DeviceMemoryBudget {

    /// Mirrors `com.apple.developer.kernel.increased-memory-limit` in
    /// `AIApp/AIApp.entitlements`.
    ///
    /// Kept as a constant rather than read back at runtime because an app
    /// cannot read its own entitlements without `SecTask` gymnastics, and this
    /// value only ever feeds the *static* catalog decision — the load gate uses
    /// `os_proc_available_memory()`, which reflects the entitlement whether or
    /// not this constant is honest. `EntitlementsMirrorTests` reads the plist
    /// out of the source tree and fails if the two ever disagree.
    static let hasIncreasedMemoryLimit = true

    /// Share of physical RAM a foreground app may reach before jetsam, without
    /// the entitlement.
    ///
    /// Calibrated against the one hard measurement this project has: a device
    /// report showing 2822 MB in use with 554 MB of headroom, i.e. a real limit
    /// of ~3376 MB — 0.41 of an 8 GiB device. iOS has never published these
    /// numbers and they move between releases, so this is deliberately a
    /// fraction rather than a table of device models: a fraction degrades
    /// gracefully on hardware that did not exist when this shipped.
    static let defaultShareOfPhysicalMemory = 0.42

    /// …and with `com.apple.developer.kernel.increased-memory-limit`.
    static let increasedShareOfPhysicalMemory = 0.62

    /// The kernel only has extra memory to hand out on devices that have it.
    /// Conservative: on a 4 GB phone the entitlement is assumed to buy nothing.
    static let increasedLimitMinimumPhysicalBytes: Int64 = 6 * 1024 * 1024 * 1024

    /// The largest amount of RAM any iPhone this app supports has — 12 GB
    /// (iPhone 17 Pro / Pro Max). iPad is not a target
    /// (`TARGETED_DEVICE_FAMILY: "1"` in project.yml), so there is no 16 GB
    /// device in scope. This is what decides whether a model is worth listing
    /// at all; raise it when a larger iPhone ships and the entries it unlocks
    /// come back on their own.
    static let bestSupportedDevicePhysicalBytes: Int64 = 12 * 1024 * 1024 * 1024

    /// Pure: the whole point is that a test can ask about an 8 GB iPhone from a
    /// simulator running on a 64 GB Mac.
    static func staticBudgetBytes(physicalMemoryBytes: Int64, increasedLimit: Bool) -> Int64 {
        let entitled = increasedLimit && physicalMemoryBytes >= increasedLimitMinimumPhysicalBytes
        let share = entitled ? increasedShareOfPhysicalMemory : defaultShareOfPhysicalMemory
        return Int64(Double(physicalMemoryBytes) * share)
    }

    static var physicalMemoryBytes: Int64 {
        Int64(bitPattern: ProcessInfo.processInfo.physicalMemory)
    }

    /// The budget the catalog and the picker are drawn against.
    static var catalogBudgetBytes: Int64 {
        staticBudgetBytes(
            physicalMemoryBytes: physicalMemoryBytes,
            increasedLimit: hasIncreasedMemoryLimit
        )
    }

    /// The budget the best supported iPhone would have. Used to decide which
    /// models are worth shipping in the catalog at all.
    static var bestSupportedDeviceBudgetBytes: Int64 {
        staticBudgetBytes(
            physicalMemoryBytes: bestSupportedDevicePhysicalBytes,
            increasedLimit: hasIncreasedMemoryLimit
        )
    }

    /// What the kernel says is left before this process is killed, or 0 when
    /// that cannot be determined.
    static var availableBytes: Int64 {
        #if canImport(os)
        let available = os_proc_available_memory()
        return available > 0 ? Int64(available) : 0
        #else
        return 0
        #endif
    }

    /// Held back from the live budget so the rest of the app — the chat UI, the
    /// thread store, an open mini-app web view — still has room to run while the
    /// model is resident. Loading a model that fits with nothing to spare just
    /// moves the kill to the next allocation.
    static let loadReserveBytes: Int64 = 192 * 1024 * 1024

    /// The budget the load gate compares against.
    ///
    /// Falls back to the static estimate when `os_proc_available_memory()`
    /// returns nothing useful, so a platform that does not answer degrades to
    /// the catalog rule rather than to no gate at all.
    static func loadBudgetBytes() -> Int64 {
        let live = availableBytes
        guard live > 0 else { return catalogBudgetBytes }
        return max(0, live - loadReserveBytes)
    }
}

/// The gate. Pure, so it is testable as a table of
/// (model id, device RAM, entitlement) → allowed / blocked.
enum LocalModelGate {

    enum Verdict: Equatable {
        case allowed
        case blocked(needBytes: Int64, budgetBytes: Int64)
        /// The id carries no inferable parameter count. Not blocked: refusing
        /// what cannot be measured would break every future or custom model id
        /// for no gain. The catalog is kept measurable by a test instead.
        case unknown
    }

    static func verdict(modelId: String, budgetBytes: Int64) -> Verdict {
        guard let need = LocalModelFootprint.peakBytes(modelId: modelId) else { return .unknown }
        return need <= budgetBytes ? .allowed : .blocked(needBytes: need, budgetBytes: budgetBytes)
    }

    static func isAllowed(modelId: String, budgetBytes: Int64) -> Bool {
        if case .blocked = verdict(modelId: modelId, budgetBytes: budgetBytes) { return false }
        return true
    }

    /// Convenience for a specific device, without touching the real one.
    static func verdict(modelId: String, physicalMemoryBytes: Int64, increasedLimit: Bool) -> Verdict {
        verdict(
            modelId: modelId,
            budgetBytes: DeviceMemoryBudget.staticBudgetBytes(
                physicalMemoryBytes: physicalMemoryBytes, increasedLimit: increasedLimit
            )
        )
    }

    /// Whether this device — as the picker sees it — can run the model.
    static func isAllowedOnThisDevice(modelId: String) -> Bool {
        isAllowed(modelId: modelId, budgetBytes: DeviceMemoryBudget.catalogBudgetBytes)
    }

    /// Whether the best iPhone in scope could ever run it. Anything that fails
    /// here is dead weight in the catalog.
    static func isAllowedOnAnySupportedDevice(modelId: String) -> Bool {
        isAllowed(modelId: modelId, budgetBytes: DeviceMemoryBudget.bestSupportedDeviceBudgetBytes)
    }

    // MARK: - Saying so, in German

    /// "1,2 GB" — one decimal, in the user's locale.
    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", locale: .current, Double(bytes) / 1_073_741_824)
    }

    /// The device's own size, as a round figure the user recognises from the
    /// spec sheet ("8 GB"), not the 7.9 GiB the kernel reports.
    static func deviceGigabytes(_ bytes: Int64) -> String {
        String(format: "%.0f GB", locale: .current, (Double(bytes) / 1_073_741_824).rounded())
    }

    /// Why a row is unavailable, in the honest form: what it needs, what the
    /// phone has, and what an app on that phone actually gets. "dieses iPhone
    /// hat 8 GB" alone invites "then why not?" — the third number answers it.
    static func shortageText(needBytes: Int64, budgetBytes: Int64, physicalMemoryBytes: Int64) -> String {
        let need = gigabytes(needBytes)
        let device = deviceGigabytes(physicalMemoryBytes)
        let budget = gigabytes(budgetBytes)
        return String(localized: "Braucht ~\(need) — dieses iPhone (\(device)) gibt einer App ~\(budget)")
    }

    /// The same, for whatever this device is.
    static func shortageTextOnThisDevice(needBytes: Int64, budgetBytes: Int64) -> String {
        shortageText(
            needBytes: needBytes,
            budgetBytes: budgetBytes,
            physicalMemoryBytes: DeviceMemoryBudget.physicalMemoryBytes
        )
    }

    /// The refusal shown when a model is loaded (not merely picked) that does
    /// not fit. Reuses the two strings the group-round abort already ships, so
    /// the user meets the same wording for the same problem in both places.
    static func refusalMessage(needBytes: Int64, budgetBytes: Int64) -> String {
        String(localized: "Zu wenig Speicher")
            + " — " + shortageTextOnThisDevice(needBytes: needBytes, budgetBytes: budgetBytes)
            + ". " + String(localized: "Ein kleineres lokales Modell wählen, oder für Gruppen einen Cloud-Anbieter.")
    }
}
