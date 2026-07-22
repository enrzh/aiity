import Foundation
import ActivityKit

/// Shared between the app and the Live Activity widget extension.
/// Shows chat/build progress on Lock Screen + Dynamic Island.
struct AgentActivityAttributes: ActivityAttributes {
    /// Fixed for the lifetime of one generation turn.
    public struct ContentState: Codable, Hashable {
        var phase: String
        var detail: String
        var progress: Double
        var isComplete: Bool
        var isError: Bool
    }

    /// User prompt snippet (static attribute).
    var promptPreview: String
    var startedAt: Date
}
