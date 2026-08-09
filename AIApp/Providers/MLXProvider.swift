import Foundation
#if canImport(MLXLLM)
import Hub
import MLX
import MLXLLM
import MLXLMCommon
#endif

/// Runs models on-device via Apple MLX. Loaded models are cached (loading a
/// 4-bit 4B model takes seconds); the Hub download base is app-controlled so
/// the settings UI can show reliable state and delete models.
final class MLXRuntime: @unchecked Sendable {
    static let shared = MLXRuntime()

    /// How many loaded models may stay resident at once.
    ///
    /// One. A 4-bit 4B model is roughly 2.3 GB and an iPhone gives the app
    /// something like 3.4 GB before jetsam — so a second resident model is not
    /// a cache, it is a guaranteed kill. Reloading costs seconds; being killed
    /// costs the conversation. Agents in a group may each name their own model,
    /// which is exactly how a second one gets loaded.
    static let maxResidentModels = 1

    #if canImport(MLXLLM)
    /// Most-recently-used last.
    private var containers: [(id: String, container: ModelContainer)] = []
    private let lock = NSLock()

    private func cache(_ container: ModelContainer, for modelId: String) {
        lock.lock()
        containers.removeAll { $0.id == modelId }
        containers.append((modelId, container))
        var evicted: [String] = []
        while containers.count > Self.maxResidentModels {
            evicted.append(containers.removeFirst().id)
        }
        lock.unlock()
        for id in evicted {
            DiagnosticsRecorder.shared.record("mlx", String(localized: "Modell aus dem Speicher entfernt: \(id)"))
        }
        if !evicted.isEmpty { MLX.GPU.clearCache() }
    }

    private func cached(_ modelId: String) -> ModelContainer? {
        lock.lock(); defer { lock.unlock() }
        guard let index = containers.firstIndex(where: { $0.id == modelId }) else { return nil }
        let entry = containers.remove(at: index)
        containers.append(entry)   // touch: most recently used
        return entry.container
    }
    #endif

    private init() {
        // Registered once, at construction, so the runtime gives memory back
        // whether or not anything else in the app is paying attention.
        MemoryPressure.shared.onPressure("mlx") { [weak self] in
            self?.evictAll()
        }
    }

    /// Drop every resident model. A generation already in flight keeps its own
    /// reference and finishes; this only releases ours, so the memory comes
    /// back when that turn ends instead of never.
    func evictAll() {
        #if canImport(MLXLLM)
        lock.lock()
        let count = containers.count
        containers.removeAll()
        lock.unlock()
        guard count > 0 else { return }
        MLX.GPU.clearCache()
        DiagnosticsRecorder.shared.record("mlx", "\(count) Modell(e) unter Speicherdruck freigegeben")
        #endif
    }

    #if canImport(MLXLLM)

    private func hub() -> HubApi {
        HubApi(downloadBase: LocalModelLocation.baseDirectory)
    }

    /// Multi-gigabyte downloads over a phone connection get interrupted — a
    /// dropped Wi-Fi packet or an idle timeout kills the whole transfer. Retry a
    /// few times instead of surfacing the first `-1001`/`-1005` as a dead end;
    /// completed files stay on disk, so each attempt resumes where the last
    /// stopped rather than starting from zero.
    private static let downloadAttempts = 4

    func ensureDownloaded(modelId: String, onProgress: @escaping (Double) -> Void) async throws {
        // Limit the Metal cache before the first model touches the GPU.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        var lastError: Error?
        for attempt in 1...Self.downloadAttempts {
            do {
                let container = try await load(modelId: modelId, onProgress: onProgress)
                cache(container, for: modelId)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                guard attempt < Self.downloadAttempts, Self.isRetriable(error) else { break }
                // Back off a little so a flapping connection has time to settle.
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
        // Keep whatever is on disk regardless of why this attempt gave up: those
        // bytes are worth gigabytes of the user's bandwidth, and
        // `HubFileDownloader` already skips any file that finished in an
        // earlier attempt — so the next attempt resumes from them.
        // `isDownloaded` already refuses to treat an incomplete directory as
        // usable, so leaving the partial files behind is safe either way.
        throw lastError ?? ProviderError.badResponse(0, "Download fehlgeschlagen.")
    }

    private func load(modelId: String, onProgress: @escaping (Double) -> Void) async throws -> ModelContainer {
        let configuration = ModelConfiguration(id: modelId)
        return try await LLMModelFactory.shared.loadContainer(hub: hub(), configuration: configuration) { progress in
            onProgress(progress.fractionCompleted)
        }
    }

    /// Transport-level failures worth another attempt; a 404 for a bad model id
    /// or a full disk is not.
    ///
    /// `NSURLErrorCancelled` is in this list on purpose. There is no cancel
    /// button in the UI today, so in practice this code only ever comes from
    /// the OS force-closing the foreground `URLSession` when the app is
    /// suspended — the ordinary way a multi-gigabyte download gets interrupted
    /// by the screen locking or the user switching apps. Treating it as fatal
    /// (the previous behavior) meant every such interruption ended the retry
    /// loop and discarded the download.
    private static func isRetriable(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable,
            NSURLErrorDataNotAllowed,
            NSURLErrorCancelled,
        ].contains(ns.code)
    }

    func container(for modelId: String) async throws -> ModelContainer {
        if let hit = cached(modelId) { return hit }
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        let configuration = ModelConfiguration(id: modelId)
        let container = try await LLMModelFactory.shared.loadContainer(hub: hub(), configuration: configuration) { _ in }
        cache(container, for: modelId)
        return container
    }
    #else
    func ensureDownloaded(modelId: String, onProgress: @escaping (Double) -> Void) async throws {
        throw ProviderError.badResponse(0, String(localized: "MLX ist in diesem Build nicht verfügbar."))
    }
    #endif

    func unload(modelId: String) {
        #if canImport(MLXLLM)
        lock.lock()
        containers.removeAll { $0.id == modelId }
        lock.unlock()
        MLX.GPU.clearCache()
        #endif
    }
}

/// LLMProvider backed by MLX. Tool use works via the <tool_call> convention
/// (native to Qwen-style chat templates, taught to others via the system
/// prompt): the model emits <tool_call>{"name":...,"arguments":{...}}</tool_call>,
/// we hold those spans back from the visible stream and surface them as
/// ChatEvent.toolCall — so local models get the same internet skills.
struct MLXProvider: LLMProvider {
    var modelId: String

    func streamChat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                #if targetEnvironment(simulator)
                continuation.finish(throwing: ProviderError.badResponse(0, String(localized: "Lokale Modelle brauchen ein echtes Gerät (MLX läuft nicht im Simulator).")))
                return
                #else
                #if canImport(MLXLLM)
                do {
                    guard LocalModelLocation.isDownloaded(modelId) else {
                        throw ProviderError.badResponse(0, String(localized: "Modell nicht heruntergeladen — bitte in den Einstellungen laden."))
                    }
                    let container = try await MLXRuntime.shared.container(for: modelId)
                    // Tools only when the policy for the on-device runtime says
                    // so (global "Web-Tools für lokale Modelle" or the
                    // per-provider setting under Anbieter → On-Device MLX); the
                    // <tool_call> convention is taught via the system prompt
                    // (buildChat).
                    let effectiveTools = LocalRuntimePolicy.shouldSendTools(
                        presetId: LocalRuntimePolicy.mlxPresetId, dialect: .mlx
                    ) ? tools : []
                    let chat = Self.buildChat(messages: messages, tools: effectiveTools)

                    let fullText: String = try await container.perform { context in
                        let input = try await context.processor.prepare(input: UserInput(chat: chat))
                        let parameters = GenerateParameters(
                            maxTokens: LocalRuntimePolicy.maxTokens,
                            temperature: Float(LocalRuntimePolicy.temperature)
                        )
                        // The emitter holds back any <tool_call> span (and a split
                        // opening tag) from the visible stream.
                        var emitter = ToolCallStreamEmitter()
                        var accumulated = ""
                        let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
                        for await generation in stream {
                            if Task.isCancelled { break }
                            if case .chunk(let piece) = generation {
                                accumulated += piece
                                if let safe = emitter.consume(accumulated: accumulated) {
                                    continuation.yield(.textDelta(safe))
                                }
                            }
                        }
                        if let tail = emitter.finish(accumulated: accumulated) {
                            continuation.yield(.textDelta(tail))
                        }
                        return accumulated
                    }
                    // Surface any tool calls the model emitted (only acted on when
                    // tools were offered; otherwise stripped from the text above).
                    if !effectiveTools.isEmpty {
                        for call in Self.extractToolCalls(from: fullText) {
                            continuation.yield(.toolCall(call))
                        }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                #else
                continuation.finish(throwing: ProviderError.badResponse(0, String(localized: "MLX ist in diesem Build nicht verfügbar.")))
                #endif
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(MLXLLM)
    private static func buildChat(messages: [ChatMessage], tools: [ToolSpec]) -> [Chat.Message] {
        var chat: [Chat.Message] = []
        for message in messages {
            switch message.role {
            case .system:
                chat.append(.system(message.text + toolInstructions(tools)))
            case .user:
                chat.append(.user(message.text))
            case .assistant:
                var text = message.text
                for call in message.toolCalls {
                    text += "\n<tool_call>{\"name\": \"\(call.name)\", \"arguments\": \(call.argumentsJSON)}</tool_call>"
                }
                chat.append(.assistant(text))
            case .tool:
                // Small chat templates handle tool results most reliably as
                // plainly labeled user turns.
                chat.append(.user("[Ergebnis von \(message.toolName ?? "tool")]\n\(message.text)"))
            }
        }
        return chat
    }
    #endif

    static func toolInstructions(_ tools: [ToolSpec]) -> String {
        guard !tools.isEmpty else { return "" }
        let specs = tools.map { spec -> String in
            let schema = String(decoding: jsonData(spec.parameters), as: UTF8.self)
            return "- \(spec.name): \(spec.description) Arguments JSON schema: \(schema)"
        }.joined(separator: "\n")
        return """


        # Tools
        You can call these tools:
        \(specs)

        To call a tool, output EXACTLY this format and then stop:
        <tool_call>{"name": "tool_name", "arguments": {...}}</tool_call>
        After the result arrives, continue answering. Only call a tool when needed.
        """
    }

    /// Extracts <tool_call>{json}</tool_call> spans from a completed answer.
    static func extractToolCalls(from text: String) -> [ToolCallData] {
        var calls: [ToolCallData] = []
        guard let regex = try? NSRegularExpression(
            pattern: #"<tool_call>\s*(\{[\s\S]*?\})\s*</tool_call>"#,
            options: []
        ) else { return calls }
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let jsonRange = Range(match.range(at: 1), in: text) else { return }
            let json = String(text[jsonRange])
            guard let object = jsonObject(Data(json.utf8)),
                  let name = object["name"] as? String else { return }
            let arguments = object["arguments"] ?? [:]
            calls.append(ToolCallData(
                id: "mlx_call_\(calls.count)",
                name: name,
                argumentsJSON: String(decoding: jsonData(arguments), as: UTF8.self)
            ))
        }
        return calls
    }
}

/// Streams visible text while holding back anything from "<tool_call>" on —
/// including a possibly split-across-chunks opening tag (keeps a small tail).
struct ToolCallStreamEmitter {
    private var emittedCount = 0
    private static let openTag = "<tool_call>"

    mutating func consume(accumulated: String) -> String? {
        let visibleEnd = Self.visibleEnd(of: accumulated, holdTail: true)
        guard visibleEnd > emittedCount else { return nil }
        let start = accumulated.index(accumulated.startIndex, offsetBy: emittedCount)
        let end = accumulated.index(accumulated.startIndex, offsetBy: visibleEnd)
        emittedCount = visibleEnd
        return String(accumulated[start..<end])
    }

    mutating func finish(accumulated: String) -> String? {
        let visibleEnd = Self.visibleEnd(of: accumulated, holdTail: false)
        guard visibleEnd > emittedCount else { return nil }
        let start = accumulated.index(accumulated.startIndex, offsetBy: emittedCount)
        let end = accumulated.index(accumulated.startIndex, offsetBy: visibleEnd)
        emittedCount = visibleEnd
        return String(accumulated[start..<end])
    }

    private static func visibleEnd(of text: String, holdTail: Bool) -> Int {
        if let tagRange = text.range(of: openTag) {
            return text.distance(from: text.startIndex, to: tagRange.lowerBound)
        }
        guard holdTail else { return text.count }
        return max(0, text.count - (openTag.count - 1))
    }
}
