import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleFoundationProvider: LLMProvider {
    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    static func availability() -> Availability {
        guard #available(iOS 26.0, *) else {
            return .unavailable(String(localized: "Benötigt iOS 26 oder neuer."))
        }
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(String(localized: "Dieses Gerät unterstützt Apple Intelligence nicht."))
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(String(localized: "Apple Intelligence ist nicht aktiviert."))
        case .unavailable(.modelNotReady):
            return .unavailable(String(localized: "Das Apple-Modell wird noch vorbereitet."))
        @unknown default:
            return .unavailable(String(localized: "Apple Foundation Models sind derzeit nicht verfügbar."))
        }
        #else
        return .unavailable(String(localized: "Foundation Models sind in diesem Build nicht verfügbar."))
        #endif
    }

    static func instructions(from messages: [ChatMessage]) -> String {
        messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
    }

    static func prompt(from messages: [ChatMessage]) -> String {
        messages.compactMap { message in
            let role: String
            switch message.role {
            case .system: return nil
            case .user: role = "User"
            case .assistant: role = "Assistant"
            case .tool: role = "Tool"
            }
            return "\(role):\n\(message.text)"
        }.joined(separator: "\n\n")
    }

    static func delta(previous: String, snapshot: String) -> String {
        snapshot.hasPrefix(previous) ? String(snapshot.dropFirst(previous.count)) : snapshot
    }

    func streamChat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if let attachment = messages.lazy.flatMap({ $0.attachments }).first {
                    continuation.finish(throwing: ProviderError.unsupportedAttachment(attachment.filename))
                    return
                }
                guard case .available = Self.availability() else {
                    let reason: String
                    if case .unavailable(let message) = Self.availability() { reason = message }
                    else { reason = String(localized: "Apple Foundation Models sind derzeit nicht verfügbar.") }
                    continuation.finish(throwing: ProviderError.badResponse(0, reason))
                    return
                }
                guard #available(iOS 26.0, *) else { return }
                #if canImport(FoundationModels)
                do {
                    let session = LanguageModelSession(instructions: Self.instructions(from: messages))
                    var previous = ""
                    for try await snapshot in session.streamResponse(to: Self.prompt(from: messages)) {
                        if Task.isCancelled { throw CancellationError() }
                        let current = snapshot.content
                        let next = Self.delta(previous: previous, snapshot: current)
                        if !next.isEmpty { continuation.yield(.textDelta(next)) }
                        previous = current
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                #else
                continuation.finish(throwing: ProviderError.badResponse(
                    0, String(localized: "Foundation Models sind in diesem Build nicht verfügbar.")
                ))
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
