import Foundation

/// Curated on-device models: small enough for iPhone RAM, instruction-tuned,
/// and known to handle the <tool_call> convention well.
struct LocalModel: Identifiable, Equatable {
    let id: String
    let displayName: String
    let details: String

    static let catalog: [LocalModel] = [
        LocalModel(
            id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen3 4B",
            details: "Standard — gutes Allround-Modell, ~2,3 GB"
        ),
        LocalModel(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B",
            details: "Leichtgewicht, ~1,8 GB"
        ),
        LocalModel(
            id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            displayName: "Qwen2.5 Coder 7B",
            details: "Beste Codequalität, ~4,3 GB — nur Geräte mit 8 GB RAM"
        ),
    ]

    static let defaultId = catalog[0].id
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
        // Mirrors swift-transformers' Hub layout below our downloadBase.
        baseDirectory.appendingPathComponent("models/\(modelId)", isDirectory: true)
    }

    static func isDownloaded(_ modelId: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: modelId).appendingPathComponent("config.json").path)
    }
}

/// Download state and lifecycle for local models. Models live in an
/// app-controlled directory (Application Support/LocalModels) so we can show
/// reliable downloaded-state and support deletion.
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
                errorMessage = "Download fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }

    func delete(_ modelId: String) {
        try? FileManager.default.removeItem(at: LocalModelLocation.directory(for: modelId))
        MLXRuntime.shared.unload(modelId: modelId)
        refresh()
    }
}
