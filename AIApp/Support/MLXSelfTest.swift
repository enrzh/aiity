#if DEBUG
import Foundation

/// Headless check that the on-device MLX path really runs: download a model,
/// generate one reply, print the verdict. Launch with
/// `AIITY_MLX_SELFTEST=<hf-model-id>` and watch the console for
/// `AIITY-MLX OK …` / `AIITY-MLX FAIL …`.
///
/// The simulator always fails by design (MLXProvider refuses there), so this
/// only tells you anything on a real device. DEBUG-only — never in a release
/// build.
enum MLXSelfTest {
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let modelId = environment["AIITY_MLX_SELFTEST"], !modelId.isEmpty else { return }
        let prompt = environment["AIITY_MLX_PROMPT"] ?? "Reply with exactly: ok"
        Task.detached(priority: .userInitiated) {
            await run(modelId: modelId, prompt: prompt)
        }
    }

    private static func run(modelId: String, prompt: String) async {
        print("AIITY-MLX START model=\(modelId)")
        let started = Date()
        do {
            if LocalModelLocation.isDownloaded(modelId) {
                print("AIITY-MLX CACHED")
            } else {
                let log = ProgressLog()
                try await MLXRuntime.shared.ensureDownloaded(modelId: modelId) { log.note($0) }
                print("AIITY-MLX DOWNLOADED in \(seconds(since: started))s")
            }

            let loadDone = Date()
            var text = ""
            let stream = MLXProvider(modelId: modelId)
                .streamChat(messages: [ChatMessage(role: .user, text: prompt)], tools: [])
            for try await event in stream {
                if case .textDelta(let piece) = event { text += piece }
            }
            let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if reply.isEmpty {
                print("AIITY-MLX FAIL empty reply after \(seconds(since: loadDone))s")
            } else {
                print("AIITY-MLX OK gen=\(seconds(since: loadDone))s reply=\(reply.prefix(160))")
            }
        } catch {
            print("AIITY-MLX FAIL \(error)")
        }
    }

    private static func seconds(since date: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(date))
    }

    /// Throttles the download callback to one line per 10% so the console stays
    /// readable. The callback arrives on arbitrary threads, hence the lock.
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lastBucket = -1

        func note(_ fraction: Double) {
            let bucket = Int(fraction * 10)
            lock.lock()
            let isNew = bucket > lastBucket
            if isNew { lastBucket = bucket }
            lock.unlock()
            if isNew { print("AIITY-MLX DOWNLOAD \(bucket * 10)%") }
        }
    }
}
#endif
