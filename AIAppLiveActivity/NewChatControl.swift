import SwiftUI
import WidgetKit

/// "Neuer Chat" in Control Center, on the Lock Screen and on the Action button.
///
/// iOS 18+ only (`ControlWidget` does not exist before it); the deployment
/// target is 17, so the whole type is gated and the bundle registers it inside
/// an `#available` block. Everything else in the suite keeps working on 17.
///
/// Stateless on purpose: a button, not a toggle, so there is no
/// `ControlValueProvider` to keep in sync and nothing to reload. The tap runs
/// `NewChatIntent`, which foregrounds the app and records the request.
///
/// German literals here on purpose — see the note in `PinnedMiniAppWidget`.
@available(iOS 18.0, *)
struct NewChatControl: ControlWidget {
    /// Reverse-DNS like every other control kind; unrelated to the widget kinds
    /// in `PinnedMiniAppStore`, which name timelines this control does not have.
    static let kind = "com.aiity.app.NewChatControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: NewChatIntent()) {
                Label("Neuer Chat", systemImage: "square.and.pencil")
            }
        }
        .displayName("Neuer Chat")
        .description("Startet in aiity eine neue Unterhaltung.")
    }
}
