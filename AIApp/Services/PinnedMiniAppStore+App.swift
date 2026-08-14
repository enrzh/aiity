import Foundation

// APP TARGET ONLY — this file must NOT be added to the `AIAppLiveActivity`
// sources: it references the SwiftData `MiniApp` model, which the widget
// process neither compiles nor could open. The shared half of the store lives
// in `PinnedMiniAppStore.swift`.

extension PinnedMiniAppStore {
    /// Pin a library record: snapshots the fields the widget draws and pokes
    /// WidgetKit. The snapshot goes stale when the record is renamed or gets a
    /// new icon — `MiniAppSpotlightIndex.reconcile` refreshes it on the next
    /// pass, and clears it entirely once the record no longer exists.
    static func pin(app: MiniApp) {
        pin(PinnedMiniApp(
            id: app.id,
            name: app.name,
            emoji: app.emoji,
            iconSymbol: app.iconSymbol
        ))
    }
}
