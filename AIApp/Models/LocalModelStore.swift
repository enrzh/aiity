import Foundation

/// On-device models (Apple MLX, mostly 4-bit). Full list is shown regardless of
/// device RAM — user chooses; larger downloads may fail or OOM on small phones.
struct LocalModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    let details: String
    /// Rough download size for UI only.
    var sizeHint: String = ""

    static let catalog: [LocalModel] = [
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
            details: "Code groß, ~8 GB+ RAM empfohlen",
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
            details: "Höhere Qualität, mehr RAM, ~8 GB",
            sizeHint: "8 GB"
        ),
        LocalModel(
            id: "mlx-community/Llama-3.3-70B-Instruct-4bit",
            displayName: "Llama 3.3 70B",
            details: "Sehr groß — nur High-RAM Geräte",
            sizeHint: "40+ GB"
        ),
        LocalModel(
            id: "mlx-community/Qwen2.5-14B-Instruct-4bit",
            displayName: "Qwen2.5 14B",
            details: "Groß, ~8 GB+",
            sizeHint: "8+ GB"
        ),
        LocalModel(
            id: "mlx-community/Qwen2.5-32B-Instruct-4bit",
            displayName: "Qwen2.5 32B",
            details: "Sehr groß — High-RAM",
            sizeHint: "18+ GB"
        ),
        LocalModel(
            id: "mlx-community/gemma-2-9b-it-4bit",
            displayName: "Gemma 2 9B",
            details: "Google groß, ~5 GB",
            sizeHint: "5 GB"
        ),
        LocalModel(
            id: "mlx-community/gemma-2-27b-it-4bit",
            displayName: "Gemma 2 27B",
            details: "Google sehr groß — High-RAM",
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

    static let defaultId = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
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

    /// Remove a partially downloaded model so the next attempt starts clean.
    static func removeIncomplete(_ modelId: String) {
        guard !isDownloaded(modelId) else { return }
        try? FileManager.default.removeItem(at: directory(for: modelId))
    }
}

/// Download state and lifecycle for local models.
@MainActor
final class LocalModelStore: ObservableObject {
    @Published var downloadedIds: Set<String> = []
    @Published var progress: [String: Double] = [:]
    @Published var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        downloadedIds = Set(LocalModel.catalog.map(\.id).filter(LocalModelLocation.isDownloaded))
    }

    func download(_ modelId: String) {
        guard progress[modelId] == nil else { return }
        progress[modelId] = 0
        errorMessage = nil
        Task {
            do {
                try await MLXRuntime.shared.ensureDownloaded(modelId: modelId) { [weak self] fraction in
                    Task { @MainActor in self?.progress[modelId] = fraction }
                }
                progress[modelId] = nil
                refresh()
            } catch {
                progress[modelId] = nil
                errorMessage = "Download fehlgeschlagen: \(error.localizedDescription). Großes Modell? Speicher/RAM prüfen — Download trotzdem möglich wenn genug freier Platz."
            }
        }
    }

    func delete(_ modelId: String) {
        try? FileManager.default.removeItem(at: LocalModelLocation.directory(for: modelId))
        MLXRuntime.shared.unload(modelId: modelId)
        refresh()
    }
}
