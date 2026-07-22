import Foundation

/// Lightweight analytics façade. Default is console/no-op — no third-party SDK.
/// Swap `handler` in tests or a future release build.
enum Analytics {
    nonisolated(unsafe) static var handler: (String, [String: String]) -> Void = { event, props in
        #if DEBUG
        if props.isEmpty {
            print("[analytics] \(event)")
        } else {
            print("[analytics] \(event) \(props)")
        }
        #endif
    }

    nonisolated static func track(_ event: String, _ props: [String: String] = [:]) {
        handler(event, props)
    }
}
