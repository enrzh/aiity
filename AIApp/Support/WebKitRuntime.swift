import WebKit

/// Brings WebKit up in this process before any of its *class-level* APIs run.
///
/// The hazard, in one sentence: `WKWebsiteDataStore`'s class methods post their
/// work to WebKit's own run loop, and that run loop does not exist until WebKit
/// has been initialised in the process — which normally only happens the first
/// time a `WKWebView` is created.
///
/// What that cost us: deleting a mini-app calls
/// `WKWebsiteDataStore.remove(forIdentifier:)` to drop its cookie jar. In a
/// launch where no web view was ever created — open the app, build a browser
/// app from "Website als App" without opening it, long-press the tile, delete —
/// the app died with EXC_BAD_ACCESS (KERN_INVALID_ADDRESS at 0x48) inside
/// `WTF::RunLoop::dispatch` → `os_unfair_lock_lock`. The record was not even
/// removed; the process was simply gone mid-delete. Reproduced twice, and
/// covered by `FullFlowUITests.testDeletingAMiniAppConfirmsInACenteredAlert`.
///
/// Touching `WKWebsiteDataStore.default()` is enough: instantiating the default
/// store initialises WebKit, run loop included, and every later class call then
/// has somewhere to dispatch to.
///
/// Which APIs actually need this was measured rather than guessed (a WebKit
/// process that calls exactly one API and nothing else):
///
/// | class API                                     | without init |
/// | --------------------------------------------- | ------------ |
/// | `WKWebsiteDataStore.remove(forIdentifier:)`   | SIGSEGV      |
/// | `WKWebsiteDataStore.fetchAllDataStoreIdentifiers` | SIGSEGV  |
/// | `WKWebsiteDataStore.default()`                | fine         |
/// | `WKWebsiteDataStore.nonPersistent()`          | fine         |
/// | `WKWebsiteDataStore(forIdentifier:)`          | fine         |
/// | `WKContentRuleListStore.default()` + compile  | fine         |
///
/// So the two crashing ones MUST be guarded. The rest are guarded anyway where
/// they are the first WebKit touch in a process, because the list above is
/// WebKit's current behaviour, not a contract it promises to keep.
///
/// Main thread only, and that is not cosmetic: calling any of these — including
/// this initialisation — off the main thread kills the process outright
/// (WebKit's own main-run-loop assertion), which is why the whole enum is
/// `@MainActor`.
@MainActor
enum WebKitRuntime {
    /// True once this process has brought WebKit up *through this helper*.
    /// Creating a `WKWebView` also initialises WebKit but does not flip this —
    /// the flag tracks the guard, not WebKit's internal state, and re-touching
    /// the default store when WebKit is already up costs one message send.
    private(set) static var isInitialised = false

    /// Call before any `WKWebsiteDataStore` class method. Idempotent and cheap;
    /// safe to call when a web view already exists.
    static func ensureInitialised() {
        guard !isInitialised else { return }
        isInitialised = true
        _ = WKWebsiteDataStore.default()
    }

    #if DEBUG
    /// Lets a test assert that a caller really does initialise WebKit first,
    /// independently of whatever ran before it in the same test process.
    static func resetForTesting() {
        isInitialised = false
    }
    #endif
}
