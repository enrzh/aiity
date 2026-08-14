import Foundation
import WidgetKit

// MARK: - Target membership
//
// Compiled into BOTH targets, like `AgentActivityAttributes.swift`: the app
// writes the pin, the widget extension reads it. project.yml must list this
// file under the `AIAppLiveActivity` sources — dropping it from either side
// breaks one half silently (the widget shows its empty state forever, or the
// app's pin action stops compiling).
//
// Because the extension compiles it too, nothing in here may reference app-only
// types (`MiniApp`, `Theme`, `DiagnosticsRecorder`, …). The app-side
// convenience that takes the SwiftData model lives in
// `PinnedMiniAppStore+App.swift`, which stays out of the extension sources.

/// The one mini-app the user pinned to the Home-Screen widget, as a snapshot.
///
/// A snapshot rather than an id for the same reason `MiniAppIndex` is one: the
/// widget process has no SwiftData container, no CloudKit, and no business
/// opening a store that carries whole HTML bundles just to draw a name and an
/// icon. The fields are refreshed by `MiniAppSpotlightIndex.reconcile` whenever
/// the underlying record changes, so a rename catches up on the next pass.
struct PinnedMiniApp: Codable, Equatable {
    var id: UUID
    var name: String
    var emoji: String
    var iconSymbol: String?
}

/// Reads and writes the pin in the shared App Group defaults — the only
/// storage both the app and the widget extension can see.
enum PinnedMiniAppStore {
    /// Must match `com.apple.security.application-groups` in BOTH targets'
    /// entitlements. Without the entitlement `UserDefaults(suiteName:)` still
    /// answers, but each process gets a private container — the app pins, the
    /// widget never sees it, no error anywhere.
    static let appGroupID = "group.com.aiity.app"

    /// The widget's `kind`. One constant so `reloadWidget()` and the widget's
    /// `StaticConfiguration` can never drift apart.
    static let widgetKind = "PinnedMiniAppWidget"

    /// The grid widget's `kind`, kept beside the pinned one for the same
    /// reason: one constant, no drift between reload calls and the widget.
    static let gridWidgetKind = "MiniAppGridWidget"

    private static let storageKey = "pinned-miniapp-v1"
    private static let recentsKey = "miniapp-recents-v1"

    /// How many apps the largest grid can show. Anything beyond this would be
    /// written on every reconcile and drawn by nobody.
    static let maxRecents = 8

    /// Test seam only (mirrors `MiniAppIndex.storageURL`): production always
    /// uses the App Group.
    static var suiteName: String = PinnedMiniAppStore.appGroupID

    static func load() -> PinnedMiniApp? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let pin = try? JSONDecoder().decode(PinnedMiniApp.self, from: data) else {
            return nil
        }
        return pin
    }

    /// Store the pin (replacing any previous one — there is exactly one pinned
    /// app) and tell WidgetKit to redraw.
    static func pin(_ app: PinnedMiniApp) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(app) else { return }
        defaults.set(data, forKey: storageKey)
        reloadWidget()
    }

    /// Remove the pin — the widget falls back to its empty state.
    static func clear() {
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: storageKey)
        reloadWidget()
    }

    /// The most recently used mini-apps, newest first — what the grid widget
    /// draws. Same snapshot bargain as the pin: the widget process must never
    /// need the SwiftData store just to paint a name and an icon.
    static func loadRecents() -> [PinnedMiniApp] {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: recentsKey),
              let apps = try? JSONDecoder().decode([PinnedMiniApp].self, from: data) else {
            return []
        }
        return apps
    }

    /// Mirror the library's newest apps into the App Group. Written by the
    /// same reconcile pass that refreshes the pin, so the two never disagree
    /// about a renamed or deleted record.
    static func saveRecents(_ apps: [PinnedMiniApp]) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let trimmed = Array(apps.prefix(maxRecents))
        guard trimmed != loadRecents() else { return }  // no redraw for no change
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults.set(data, forKey: recentsKey)
        reloadWidgets()
    }

    /// Fire-and-forget: with no widget on any Home Screen this is a no-op, so
    /// callers never need to know whether one is installed.
    static func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    /// Both widget kinds — the pin and the grid draw from the same store, so a
    /// change to either half redraws both.
    static func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: gridWidgetKind)
    }
}

/// The `aiity://miniapp/<uuid>` deep link the widget taps into the app.
///
/// The `aiity` scheme already belongs to OAuth callbacks
/// (`CFBundleURLTypes` in project.yml, consumed by `ASWebAuthenticationSession`
/// in `OAuthService`). Those never reach `onOpenURL` while a session is
/// presenting — the session swallows its own callback — and `miniAppId(from:)`
/// answers `nil` for every URL whose host is not exactly `miniapp`, so the
/// root's handler can run unconditionally without disturbing them.
enum MiniAppDeepLink {
    static let scheme = "aiity"
    static let host = "miniapp"

    /// `aiity://chat` — open the app on a fresh conversation. Used by the
    /// Control Center control and the grid widget's compose button, both of
    /// which live in the extension and cannot reach `IntentRouter` directly.
    static let chatURL = URL(string: "aiity://chat")!

    /// True for exactly `aiity://chat`, so the root can route it without
    /// having to parse anything else.
    static func isNewChat(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == "chat"
    }

    /// `aiity://miniapp/<uuid>`. Optional only because `URLComponents` is —
    /// a scheme, a fixed host and a UUID path always render.
    static func url(for id: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + id.uuidString
        return components.url
    }

    /// The mini-app a URL points at, or `nil` for anything that is not a
    /// well-formed `aiity://miniapp/<uuid>` — other hosts (OAuth callbacks),
    /// other schemes (`aiapp://`), or a malformed id.
    static func miniAppId(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              url.pathComponents.count == 2 else {
            return nil
        }
        return UUID(uuidString: url.pathComponents[1])
    }
}
