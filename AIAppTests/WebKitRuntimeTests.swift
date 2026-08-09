import XCTest
import WebKit
@testable import AIApp

/// WebKit's `WKWebsiteDataStore` class methods dispatch onto a run loop that
/// does not exist until WebKit has been initialised in the process, and calling
/// them first thing after launch is a hard SIGSEGV, not an exception — a crash
/// no `try?` can catch and no unit test can survive. `WebKitRuntime` is the one
/// place that brings WebKit up; these tests keep every caller wired to it.
///
/// These were checked against a deliberately broken build. With the guard
/// commented out of `removeSessionStore`, running this suite on its own
/// (`-only-testing:AIAppTests/WebKitRuntimeTests`) killed the test host outright
/// — twice, xcodebuild relaunching it each time and reporting "Restarting after
/// unexpected exit, crash, or test timeout" — and the source guard below failed
/// with the offending line number. Both pass with the guard back.
///
/// One honest caveat: the crash only happens when this suite runs FIRST in a
/// process. In a full run, earlier tests have already created web views, so an
/// unguarded call would quietly succeed and only the source scan would catch it.
/// That is exactly why the source scan exists alongside the runtime checks.
/// The device-level proof is
/// `FullFlowUITests.testDeletingAMiniAppConfirmsInACenteredAlert`, which killed
/// the app before the guard existed.
@MainActor
final class WebKitRuntimeTests: XCTestCase {

    /// Every entry point calls this, so it has to be free after the first time.
    func testInitialisingIsIdempotent() {
        WebKitRuntime.resetForTesting()
        XCTAssertFalse(WebKitRuntime.isInitialised)
        WebKitRuntime.ensureInitialised()
        XCTAssertTrue(WebKitRuntime.isInitialised)
        WebKitRuntime.ensureInitialised()
        XCTAssertTrue(WebKitRuntime.isInitialised, "a second call must stay a no-op")
    }

    /// Deleting a mini-app is the path that actually crashed: it is the only
    /// mini-app action reachable with no web view anywhere in the process.
    /// Resetting first makes this independent of whatever ran before it.
    func testDeletingASessionStoreBringsWebKitUpFirst() {
        WebKitRuntime.resetForTesting()
        MiniAppRunnerView.removeSessionStore(for: UUID().uuidString)
        XCTAssertTrue(WebKitRuntime.isInitialised,
                      "removeSessionStore must initialise WebKit before calling a class API")
    }

    /// The fetch tool reaches WebKit class APIs (`nonPersistent()`, the content
    /// rule list store) before it builds its web view, on turns that may be the
    /// first WebKit use in the process.
    func testTheBrowserFetchEntryPointBringsWebKitUpFirst() async {
        WebKitRuntime.resetForTesting()
        // Unroutable by design: the point is that the entry point runs its
        // WebKit setup, not that the load succeeds.
        _ = try? await BrowserFetch().text(from: URL(string: "http://127.0.0.1:1/")!,
                                           allowPrivateHosts: false)
        XCTAssertTrue(WebKitRuntime.isInitialised,
                      "BrowserFetch must initialise WebKit before touching its class APIs")
    }

    // MARK: - future call sites

    /// The two class APIs that are fatal without initialisation. Measured, not
    /// assumed: a process calling only one of these and nothing else dies with
    /// SIGSEGV for exactly these two, while `default()`, `nonPersistent()`,
    /// `WKWebsiteDataStore(forIdentifier:)` and `WKContentRuleListStore` survive.
    private static let fatalWithoutInitialisation = [
        "WKWebsiteDataStore.remove(forIdentifier:",
        "WKWebsiteDataStore.fetchAllDataStoreIdentifiers",
    ]

    /// A source guard, deliberately: the runtime tests above only cover the
    /// callers that exist today, and the whole risk is a *new* one being added
    /// somewhere no test looks — a cleanup sweep, a sign-out reset, an import
    /// handler. Any such call must have `WebKitRuntime.ensureInitialised()` in
    /// front of it.
    func testEveryFatalClassAPICallIsPrecededByTheGuard() throws {
        let root = URL(fileURLWithPath: #filePath)   // AIAppTests/WebKitRuntimeTests.swift
            .deletingLastPathComponent()             // AIAppTests/
            .deletingLastPathComponent()             // repo root
            .appendingPathComponent("AIApp")
        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: nil) else {
            throw XCTSkip("app sources not readable from \(root.path)")
        }

        var checked = 0
        for case let file as URL in walker where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///"),
                      Self.fatalWithoutInitialisation.contains(where: code.contains) else { continue }
                checked += 1
                // The guard belongs in the same short function, so a small
                // lookback is the right window — anything further away is not
                // obviously ordered before the call.
                let window = lines[max(0, index - 12)..<index].joined(separator: "\n")
                XCTAssertTrue(window.contains("WebKitRuntime.ensureInitialised()"),
                              """
                              \(file.lastPathComponent):\(index + 1) calls a WebKit class API that \
                              segfaults when WebKit has not been initialised in this process. \
                              Call WebKitRuntime.ensureInitialised() first.
                              """)
            }
        }
        XCTAssertGreaterThan(checked, 0, "the scan found no call sites — the patterns went stale")
    }
}
