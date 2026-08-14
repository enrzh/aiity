import WidgetKit
import SwiftUI

@main
struct AIAppLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        AgentLiveActivityWidget()
        PinnedMiniAppWidget()
        MiniAppGridWidget()
        // `ControlWidget` is iOS 18; the deployment target is 17, so the
        // control drops out of the bundle on older systems instead of the whole
        // extension failing to build.
        if #available(iOS 18.0, *) {
            NewChatControl()
        }
    }
}
