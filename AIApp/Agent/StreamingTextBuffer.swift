import Foundation

/// Coalesces token-sized stream deltas into bounded UI updates.
///
/// Providers often emit a handful of characters at a time. Publishing every
/// delta makes SwiftUI re-render the conversation hundreds of times per
/// second. This value stays local to one stream and returns a chunk on the next
/// incoming delta after enough time or text has accumulated; `flush()`
/// preserves the final tail when a provider pauses or finishes.
struct StreamingTextBuffer {
    private let interval: TimeInterval
    private let characterThreshold: Int
    private var pending = ""
    private var lastEmission: Date?

    init(interval: TimeInterval = 1.0 / 30.0, characterThreshold: Int = 200) {
        self.interval = max(0, interval)
        self.characterThreshold = max(1, characterThreshold)
    }

    mutating func append(_ delta: String, at now: Date = Date()) -> String? {
        guard !delta.isEmpty else { return nil }
        pending += delta

        if lastEmission == nil {
            lastEmission = now
        }

        guard pending.count >= characterThreshold
                || now.timeIntervalSince(lastEmission ?? now) >= interval else {
            return nil
        }
        return emit(at: now)
    }

    mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let chunk = pending
        pending = ""
        return chunk
    }

    private mutating func emit(at now: Date) -> String {
        let chunk = pending
        pending = ""
        lastEmission = now
        return chunk
    }
}
