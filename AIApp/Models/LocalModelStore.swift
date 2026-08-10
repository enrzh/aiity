import Foundation
import UIKit

/// On-device models (Apple MLX, mostly 4-bit).
///
/// The list used to be shown in full regardless of device RAM, on the theory
/// that the user chooses and a too-large model merely "may fail". It does not
/// fail — it gets the app killed by jetsam with no crash report, which is
/// exactly what five TestFlight crashes in fourteen minutes on one iPhone 16
/// Pro turned out to be. `LocalModelFootprint` now decides, and it decides in
/// two places: entries that no supported iPhone could ever run are not in
/// `catalog` at all, and what remains is gated per device by `LocalModelGate`.
struct LocalModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    let details: String
    /// Rough DOWNLOAD size, for UI only.
    ///
    /// Explicitly not a memory figure and never used as one: it is the weights
    /// on disk, before the KV cache and the MLX runtime exist. Treating it as a
    /// footprint understates a 4B model by about 60 %. Ask
    /// `LocalModelFootprint.peakBytes(modelId:)` for memory.
    var sizeHint: String = ""

    /// Everything this app knows how to run, before device filtering.
    /// `catalog` is the part worth offering; see there.
    static let allCandidates: [LocalModel] = [
        // —— Ultra light ——
        LocalModel(
            id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
            displayName: "Llama 3.2 1B",
            details: "Ultraleicht, ~0,7 GB",
            sizeHint: "0.7 GB"
        ),
        LocalModel(
            id: "mlx-community/gemma-3-1b-it-4bit",
            displayName: "Gemma 3 1B",
            details: "Google, ultraleicht, ~0,8 GB",
            sizeHint: "0.8 GB"
        ),
        LocalModel(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            displayName: "Qwen2.5 0.5B",
            details: "Winzig / schnell, ~0,4 GB",
            sizeHint: "0.4 GB"
        ),
        LocalModel(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            displayName: "Qwen2.5 1.5B",
            details: "Sehr leicht, ~1,0 GB",
            sizeHint: "1.0 GB"
        ),
        LocalModel(
            id: "mlx-community/SmolLM2-1.7B-Instruct-4bit",
            displayName: "SmolLM2 1.7B",
            details: "HuggingFace klein, ~1,1 GB",
            sizeHint: "1.1 GB"
        ),
        // —— Small / mid ——
        LocalModel(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B",
            details: "Leichtgewicht, ~1,8 GB",
            sizeHint: "1.8 GB"
        ),
        LocalModel(
            id: "mlx-community/Phi-3.5-mini-instruct-4bit",
            displayName: "Phi-3.5 mini",
            details: "Microsoft, Logik & Code, ~2,1 GB",
            sizeHint: "2.1 GB"
        ),
        LocalModel(
            id: "mlx-community/Phi-4-mini-instruct-4bit",
            displayName: "Phi-4 mini",
            details: "Microsoft neuer, ~2,5 GB",
            sizeHint: "2.5 GB"
        ),
        LocalModel(
            id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen3 4B",
            details: "Gutes Allround, ~2,3 GB",
            sizeHint: "2.3 GB"
        ),
        LocalModel(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            displayName: "Qwen2.5 3B",
            details: "Ausgewogen, ~1,9 GB",
            sizeHint: "1.9 GB"
        ),
        LocalModel(
            id: "mlx-community/gemma-3-4b-it-4bit",
            displayName: "Gemma 3 4B",
            details: "Google, ~3,0 GB",
            sizeHint: "3.0 GB"
        ),
        LocalModel(
            id: "mlx-community/gemma-2-2b-it-4bit",
            displayName: "Gemma 2 2B",
            details: "Google, kompakt, ~1,5 GB",
            sizeHint: "1.5 GB"
        ),
        LocalModel(
            id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
            displayName: "Mistral 7B Instruct",
            details: "Klassiker, ~4,0 GB",
            sizeHint: "4.0 GB"
        ),
        // —— Code-focused ——
        LocalModel(
            id: "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit",
            displayName: "Qwen2.5 Coder 3B",
            details: "Code, leichter, ~1,9 GB",
            sizeHint: "1.9 GB"
        ),
        LocalModel(
            id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            displayName: "Qwen2.5 Coder 7B",
            details: "Code stark, ~4,3 GB",
            sizeHint: "4.3 GB"
        ),
        LocalModel(
            id: "mlx-community/Qwen2.5-Coder-14B-Instruct-4bit",
            displayName: "Qwen2.5 Coder 14B",
            details: String(localized: "Code groß, ~8 GB+ RAM empfohlen"),
            sizeHint: "8+ GB"
        ),
        LocalModel(
            id: "mlx-community/deepseek-coder-6.7b-instruct-4bit",
            displayName: "DeepSeek Coder 6.7B",
            details: "Code, ~3,8 GB",
            sizeHint: "3.8 GB"
        ),
        // —— Larger general ——
        LocalModel(
            id: "mlx-community/Qwen3-8B-4bit",
            displayName: "Qwen3 8B",
            details: "Starkes Allround, ~4,5 GB",
            sizeHint: "4.5 GB"
        ),
        LocalModel(
            id: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            displayName: "Llama 3.1 8B",
            details: "Vielseitig, ~4,5 GB",
            sizeHint: "4.5 GB"
        ),
        LocalModel(
            id: "mlx-community/Meta-Llama-3.1-8B-Instruct-8bit",
            displayName: "Llama 3.1 8B (8-bit)",
            details: String(localized: "Höhere Qualität, mehr RAM, ~8 GB"),
            sizeHint: "8 GB"
        ),
        LocalModel(
            id: "mlx-community/Llama-3.3-70B-Instruct-4bit",
            displayName: "Llama 3.3 70B",
            details: String(localized: "Sehr groß — nur High-RAM Geräte"),
            sizeHint: "40+ GB"
        ),
        LocalModel(
            id: "mlx-community/Qwen2.5-14B-Instruct-4bit",
            displayName: "Qwen2.5 14B",
            details: String(localized: "Groß, ~8 GB+"),
            sizeHint: "8+ GB"
        ),
        LocalModel(
            id: "mlx-community/Qwen2.5-32B-Instruct-4bit",
            displayName: "Qwen2.5 32B",
            details: String(localized: "Sehr groß — High-RAM"),
            sizeHint: "18+ GB"
        ),
        LocalModel(
            id: "mlx-community/gemma-2-9b-it-4bit",
            displayName: "Gemma 2 9B",
            details: String(localized: "Google groß, ~5 GB"),
            sizeHint: "5 GB"
        ),
        LocalModel(
            id: "mlx-community/gemma-2-27b-it-4bit",
            displayName: "Gemma 2 27B",
            details: String(localized: "Google sehr groß — High-RAM"),
            sizeHint: "15+ GB"
        ),
        LocalModel(
            id: "mlx-community/Mistral-Nemo-Instruct-2407-4bit",
            displayName: "Mistral Nemo 12B",
            details: "Mistral 12B-Klasse, ~7 GB",
            sizeHint: "7 GB"
        ),
        LocalModel(
            id: "mlx-community/Phi-3-mini-4k-instruct-4bit",
            displayName: "Phi-3 mini 4k",
            details: "Microsoft klassisch, ~2,2 GB",
            sizeHint: "2.2 GB"
        ),
        LocalModel(
            id: "mlx-community/OpenELM-3B-Instruct-4bit",
            displayName: "OpenELM 3B",
            details: "Apple OpenELM, ~1,8 GB",
            sizeHint: "1.8 GB"
        ),
        LocalModel(
            id: "mlx-community/stablelm-2-zephyr-1_6b-4bit",
            displayName: "StableLM 2 Zephyr 1.6B",
            details: "Leicht / chatty, ~1,0 GB",
            sizeHint: "1.0 GB"
        ),
        LocalModel(
            id: "mlx-community/internlm2_5-7b-chat-4bit",
            displayName: "InternLM2.5 7B",
            details: "Mehrsprachig, ~4 GB",
            sizeHint: "4 GB"
        ),
    ]

    /// What the app offers: every candidate the best iPhone in scope could
    /// actually run.
    ///
    /// # Why removed rather than permanently shown as blocked
    ///
    /// A row that is blocked on *this* phone but runs on another is
    /// informative — it tells the user what a bigger device would buy them, and
    /// it comes back when they upgrade. A row that no iPhone can run is a
    /// promise the product cannot keep on any hardware: it invites the download
    /// (multiple gigabytes of the user's bandwidth), it generates "why can't
    /// I?" support, and it is the exact UI that produced the crashes. The app
    /// is iPhone-only (`TARGETED_DEVICE_FAMILY: "1"`), so the ceiling is the
    /// 12 GB iPhone 17 Pro — nothing above roughly 9B at 4-bit clears it.
    ///
    /// Filtered rather than deleted by hand so this stays one mechanism with
    /// one calibration: raising
    /// `DeviceMemoryBudget.bestSupportedDevicePhysicalBytes` when a larger
    /// iPhone ships brings the bigger models back with no edit to the list.
    ///
    /// Dropped at 12 GB today: Qwen2.5 14B, Qwen2.5 Coder 14B, Gemma 2 27B,
    /// Qwen2.5 32B, Llama 3.3 70B, Mistral Nemo 12B, and the 8-bit Llama 3.1 8B
    /// (8-bit doubles the weights of a model that only just fits at 4-bit).
    static let catalog: [LocalModel] = allCandidates.filter {
        LocalModelGate.isAllowedOnAnySupportedDevice(modelId: $0.id)
    }

    static let defaultId = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    /// The rows the settings screen shows: the catalog, plus anything already
    /// sitting on disk from before it was filtered out.
    ///
    /// Without the second part an existing 8 GB download of a now-dropped model
    /// becomes invisible and therefore undeletable — the app would keep the
    /// user's storage hostage as a side effect of getting safer.
    static func rows(downloadedIds: Set<String>) -> [LocalModel] {
        let listed = Set(catalog.map(\.id))
        return catalog + allCandidates.filter {
            !listed.contains($0.id) && downloadedIds.contains($0.id)
        }
    }
}

/// Filesystem layout for on-device models — free of actor isolation because
/// the MLX provider resolves paths from background tasks.
enum LocalModelLocation {
    static let baseDirectory: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static func directory(for modelId: String) -> URL {
        baseDirectory.appendingPathComponent("models/\(modelId)", isDirectory: true)
    }

    /// A model counts as downloaded only when its weights are on disk, not just
    /// `config.json`. The Hub writes the small metadata files first, so an
    /// interrupted download otherwise looks complete — the UI shows "ready" and
    /// every generation then fails with an opaque network error while MLX tries
    /// to fetch the missing tensors.
    static func isDownloaded(_ modelId: String) -> Bool {
        isComplete(directory: directory(for: modelId))
    }

    static func isComplete(directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent("config.json").path),
              let entries = try? fm.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: [.fileSizeKey]
              ) else {
            return false
        }
        let weights = entries.filter {
            ["safetensors", "npz", "gguf", "bin"].contains($0.pathExtension.lowercased())
        }
        guard !weights.isEmpty else { return false }
        // A zero-byte placeholder is what a killed download leaves behind.
        return weights.allSatisfy { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size > 0
        }
    }

}

/// Download state and lifecycle for local models.
///
/// A SINGLETON, not a per-screen `@StateObject`. This view is reached by
/// `NavigationLink`, which fully deallocates the destination (and any
/// `@StateObject` it owns) on pop — but `download()`'s `Task` has no tie to
/// the view's lifetime and keeps running regardless. A per-view instance
/// meant a download survived navigating away, invisibly, while the FRESH
/// instance created by navigating back showed "not downloaded" (its own
/// `progress` dict starts empty) — inviting a second, concurrent download of
/// the same files, and making `delete()` look like it silently didn't work
/// when the zombie download recreated the very files just removed. A shared
/// instance means every screen sees the same in-flight state.
@MainActor
final class LocalModelStore: ObservableObject {
    static let shared = LocalModelStore()

    @Published var downloadedIds: Set<String> = []
    @Published var progress: [String: Double] = [:]
    @Published var errorMessage: String?

    /// Independent of `AppPreferences.keepScreenAwakeWhileBuilding` — that flag
    /// is driven centrally by agent-turn state (AppPreferences.swift), and a
    /// second, uncoordinated writer of `isIdleTimerDisabled` would race it.
    /// `beginBackgroundTask` alone still buys the OS's background grace period
    /// (the same mechanism AgentLiveActivityController already uses for agent
    /// turns), which is what actually matters: it is the app being suspended,
    /// not merely the screen dimming, that kills a foreground download.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        refresh()
    }

    /// Scans `allCandidates`, not `catalog`: a model that was downloaded before
    /// the footprint filter dropped it is still on disk, and has to stay
    /// visible long enough to be deleted.
    func refresh() {
        downloadedIds = Set(LocalModel.allCandidates.map(\.id).filter(LocalModelLocation.isDownloaded))
    }

    /// Whether this device can run the model at all — the picker's own gate,
    /// and the reason the download button is disabled rather than merely
    /// discouraged. `details` prose ("nur High-RAM Geräte") was the previous
    /// mechanism, and it is what shipped the crash.
    func canRun(_ modelId: String) -> Bool {
        LocalModelGate.isAllowedOnThisDevice(modelId: modelId)
    }

    /// The blocking reason, or `nil` when there is none.
    func shortage(_ modelId: String) -> String? {
        guard case .blocked(let need, let budget) = LocalModelGate.verdict(
            modelId: modelId, budgetBytes: DeviceMemoryBudget.catalogBudgetBytes
        ) else { return nil }
        return LocalModelGate.shortageTextOnThisDevice(needBytes: need, budgetBytes: budget)
    }

    func download(_ modelId: String) {
        guard progress[modelId] == nil else { return }
        // Refuse here as well as in the UI: downloading a model this phone can
        // never load spends gigabytes of the user's data to reach a model that
        // only ever produces an error. The runtime refuses the load too — see
        // MLXRuntime.assertFits — because a selection can arrive from another
        // device through iCloud settings sync without passing this screen.
        if case .blocked(let need, let budget) = LocalModelGate.verdict(
            modelId: modelId, budgetBytes: DeviceMemoryBudget.catalogBudgetBytes
        ) {
            errorMessage = LocalModelGate.refusalMessage(needBytes: need, budgetBytes: budget)
            return
        }
        progress[modelId] = 0
        errorMessage = nil
        beginBackgroundProtection()
        Task {
            defer { endBackgroundProtectionIfIdle() }
            do {
                try await MLXRuntime.shared.ensureDownloaded(modelId: modelId) { [weak self] fraction in
                    Task { @MainActor in self?.progress[modelId] = fraction }
                }
                progress[modelId] = nil
                refresh()
            } catch {
                progress[modelId] = nil
                errorMessage = String(localized: "Download fehlgeschlagen: \(error.localizedDescription). Großes Modell? Speicher/RAM prüfen — Download trotzdem möglich wenn genug freier Platz.")
            }
        }
    }

    func delete(_ modelId: String) {
        do {
            try FileManager.default.removeItem(at: LocalModelLocation.directory(for: modelId))
        } catch {
            let ns = error as NSError
            if ns.code != NSFileNoSuchFileError {
                errorMessage = String(localized: "Löschen fehlgeschlagen: \(error.localizedDescription)")
            }
        }
        MLXRuntime.shared.unload(modelId: modelId)
        refresh()
    }

    private func beginBackgroundProtection() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "aiity.model-download") { [weak self] in
            Task { @MainActor in self?.endBackgroundProtectionIfIdle(force: true) }
        }
    }

    /// Ends the background task once nothing is downloading — or immediately,
    /// if the OS is about to force-end it anyway (`force`, from the expiration
    /// handler above).
    private func endBackgroundProtectionIfIdle(force: Bool = false) {
        guard (force || progress.isEmpty), backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
