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

    #if canImport(MLXLLM)
    private var containers: [String: ModelContainer] = [:]
    private let lock = NSLock()

    private func hub() -> HubApi {
        HubApi(downloadBase: LocalModelLocation.baseDirectory)
    }

    func ensureDownloaded(modelId: String, onProgress: @escaping (Double) -> Void) async throws {
        // Limit the Metal cache before the first model touches the GPU.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        let configuration = ModelConfiguration(id: modelId)
        let container = try await LLMModelFactory.shared.loadContainer(hub: hub(), configuration: configuration) { progress in
            onProgress(progress.fractionCompleted)
        }
        lock.lock()
        containers[modelId] = container
        lock.unlock()
    }

    func container(for modelId: String) async throws -> ModelContainer {
        lock.lock()
        let cached = containers[modelId]
        lock.unlock()
        if let cached { return cached }
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        let configuration = ModelConfiguration(id: modelId)
        let container = try await LLMModelFactory.shared.loadContainer(hub: hub(), configuration: configuration) { _ in }
        lock.lock()
        containers[modelId] = container
        lock.unlock()
        return container
    }
    #else
    func ensureDownloaded(modelId: String, onProgress: @escaping (Double) -> Void) async throws {
        throw ProviderError.badResponse(0, "MLX ist in diesem Build nicht verfügbar.")
    }
    #endif

    func unload(modelId: String) {
        #if canImport(MLXLLM)
        lock.lock()
        containers[modelId] = nil
        lock.unlock()
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
                continuation.finish(throwing: ProviderError.badResponse(0, "Lokale Modelle brauchen ein echtes Gerät (MLX läuft nicht im Simulator)."))
                return
                #else
                #if canImport(MLXLLM)
                do {
                    guard LocalModelLocation.isDownloaded(modelId) else {
                        throw ProviderError.badResponse(0, "Modell nicht heruntergeladen — bitte in den Einstellungen laden.")
                    }
                    let container = try await MLXRuntime.shared.container(for: modelId)
                    let chat = Self.buildChat(messages: messages, tools: tools)

                    let fullText: String = try await container.perform { context in
                        var emitter = ToolCallStreamEmitter()
                        let input = try await context.processor.prepare(input: UserInput(chat: chat))
                        let parameters = GenerateParameters(maxTokens: 8192, temperature: 0.7)
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
                    for call in Self.extractToolCalls(from: fullText) {
                        continuation.yield(.toolCall(call))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                #else
                continuation.finish(throwing: ProviderError.badResponse(0, "MLX ist in diesem Build nicht verfügbar."))
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
        // No complete tag yet — hold back a tail that could be a partial one.
        return max(0, text.count - (openTag.count - 1))
    }
}
