import XCTest
@testable import AIApp

/// Proves the browser path does the one thing a plain fetch cannot: run the
/// page's JavaScript. Served from a local stub so the test is hermetic — no
/// live site, no network flakiness.
@MainActor
final class BrowserFetchTests: XCTestCase {
    private var server: LocalPageServer!

    override func setUpWithError() throws {
        server = try LocalPageServer()
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    /// The document body is empty until a script fills it — exactly the shape
    /// that returns nothing through URLSession.
    func testRendersJavaScriptBuiltContent() async throws {
        let html = """
        <html><body><div id="app"></div>
        <script>
          document.getElementById('app').textContent =
            'Der Preis betraegt 42 Euro und wurde per Skript gesetzt.';
        </script></body></html>
        """
        let url = server.serve(html: html, at: "/js")

        // What the cheap path would see: no readable text at all.
        let staticText = FetchURLTool.extractTextForTesting(fromHTML: html)
        XCTAssertFalse(staticText.contains("42 Euro"),
                       "the raw HTML must not already contain the scripted text")

        let rendered = try await BrowserFetch().text(from: url, allowPrivateHosts: true)
        XCTAssertTrue(rendered.contains("42 Euro"),
                      "the browser should run the script; got: \(rendered.prefix(200))")
    }

    /// `innerText` respects rendering, so chrome that is hidden or scripted
    /// away does not pollute the text handed to the model.
    func testSkipsScriptStyleAndHiddenElements() async throws {
        let html = """
        <html><head><style>.gone { display: none; }</style></head>
        <body>
          <script>var noise = 'SCRIPTSOURCE';</script>
          <div class="gone">VERSTECKT</div>
          <article>Sichtbarer Artikeltext.</article>
        </body></html>
        """
        let url = server.serve(html: html, at: "/hidden")

        let rendered = try await BrowserFetch().text(from: url, allowPrivateHosts: true)
        XCTAssertTrue(rendered.contains("Sichtbarer Artikeltext"))
        XCTAssertFalse(rendered.contains("SCRIPTSOURCE"), "script source is not page text")
        XCTAssertFalse(rendered.contains("VERSTECKT"), "display:none is not page text")
    }

    /// The SSRF guard must apply to the browser path too — it follows
    /// redirects itself, so the initial-host check is not enough.
    func testRefusesPrivateHostsWhenNotAllowed() async {
        let url = server.serve(html: "<html><body>egal</body></html>", at: "/private")
        do {
            _ = try await BrowserFetch().text(from: url, allowPrivateHosts: false)
            XCTFail("a loopback address must be refused when private hosts are disallowed")
        } catch {
            // Expected: blocked before any load completes.
        }
    }
}

/// Minimal HTTP server on a loopback port, so these tests never touch the network.
private final class LocalPageServer {
    /// Shared with the listener's connection handler, which runs off-thread.
    private let pages = PageBox()
    private let listener: NWListenerBox

    init() throws {
        let pages = self.pages
        listener = try NWListenerBox { path in pages.page(path) }
    }

    func serve(html: String, at path: String) -> URL {
        pages.set(html, for: path)
        return URL(string: "http://127.0.0.1:\(listener.port)\(path)")!
    }

    func stop() { listener.stop() }
}

/// Locked page table — written from the test thread, read from the network one.
private final class PageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [String: String] = [:]

    func set(_ html: String, for path: String) {
        lock.lock(); pages[path] = html; lock.unlock()
    }

    func page(_ path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return pages[path]
    }
}

import Network

/// Tiny NWListener wrapper that answers GETs with a stored page.
private final class NWListenerBox {
    let port: UInt16
    private let listener: NWListener

    init(page: @escaping (String) -> String?) throws {
        let parameters = NWParameters.tcp
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var resolvedPort: UInt16 = 0

        let started = listener
        started.stateUpdateHandler = { state in
            if case .ready = state {
                resolvedPort = started.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let path = request
                    .split(separator: " ")
                    .dropFirst()
                    .first
                    .map(String.init) ?? "/"
                let body = page(path) ?? "<html><body>404</body></html>"
                let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r
                \(body)
                """
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = resolvedPort
    }

    func stop() { listener.cancel() }
}

/// The browser mini-app's open-target marker, and the invariant that a remote
/// document must not be treated as our trusted shell.
final class WebAppTargetTests: XCTestCase {
    func testGeneratedBrowserAppDeclaresItsTarget() {
        let html = WebAppBuilder.html(urlString: "x.com", name: "X")
        XCTAssertEqual(WebAppBuilder.openTarget(in: html)?.absoluteString, "https://x.com")
        XCTAssertTrue(html.contains("capability: browser"))
    }

    func testBareHostGetsHTTPS() {
        let html = WebAppBuilder.html(urlString: "example.com")
        XCTAssertEqual(WebAppBuilder.openTarget(in: html)?.scheme, "https")
    }

    /// Only http(s) may become a directly-loaded document.
    func testNonWebSchemesAreNotOpenTargets() {
        for raw in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,x"] {
            XCTAssertNil(
                WebAppBuilder.openTarget(in: "<!-- open: \(raw) -->"),
                "must refuse \(raw)"
            )
        }
    }

    /// An ordinary generated mini-app has no marker, so it still renders its
    /// own HTML rather than navigating anywhere.
    func testPlainMiniAppHasNoOpenTarget() {
        XCTAssertNil(WebAppBuilder.openTarget(in: "<html><body>hallo</body></html>"))
    }
}

/// The single fetch-target gate the three transports share.
final class NetworkTargetValidatorTests: XCTestCase {
    func testPrivateAndDisguisedAddressesAreBlocked() {
        for host in ["127.0.0.1", "localhost", "10.0.0.5", "192.168.1.10",
                     "169.254.1.1", "100.64.0.1", "nas.local", "2130706433"] {
            XCTAssertTrue(NetworkTargetValidator.isBlocked(host: host), "should block \(host)")
        }
    }

    func testPublicAddressesAreAllowed() {
        for host in ["example.com", "8.8.8.8", "api.openai.com", "1.1.1.1"] {
            XCTAssertFalse(NetworkTargetValidator.isBlocked(host: host), "should allow \(host)")
        }
    }

    func testNonWebSchemesAreNeverAllowed() {
        for raw in ["file:///etc/passwd", "ftp://example.com", "javascript:alert(1)"] {
            guard let url = URL(string: raw) else { continue }
            XCTAssertFalse(NetworkTargetValidator.isAllowed(url, allowPrivate: true),
                           "must refuse \(raw) even when private hosts are allowed")
        }
    }

    /// The allowance exists for the user's own LAN runtime, and must apply only
    /// when explicitly granted.
    func testPrivateHostsOnlyWithExplicitAllowance() {
        let url = URL(string: "http://192.168.1.10:11434/v1")!
        XCTAssertFalse(NetworkTargetValidator.isAllowed(url, allowPrivate: false))
        XCTAssertTrue(NetworkTargetValidator.isAllowed(url, allowPrivate: true))
    }

    func testRefusalReasonNamesTheHost() {
        let url = URL(string: "http://10.1.2.3/secret")!
        let reason = NetworkTargetValidator.refusalReason(for: url, allowPrivate: false)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("10.1.2.3") == true, "the reason should name the refused host")
        XCTAssertNil(NetworkTargetValidator.refusalReason(for: url, allowPrivate: true))
    }
}

/// Guards the per-mini-app session isolation.
final class StableIdentifierTests: XCTestCase {
    func testDerivationIsStableAcrossCalls() {
        XCTAssertEqual(StableIdentifier.uuid(from: "app-a"), StableIdentifier.uuid(from: "app-a"))
    }

    /// The bug this exists to fix: different apps must not share a store.
    func testDifferentValuesGetDifferentIdentifiers() {
        XCTAssertNotEqual(StableIdentifier.uuid(from: "app-a"), StableIdentifier.uuid(from: "app-b"))
    }

    /// Existing saved apps keep their identity, so their sessions survive.
    func testRealUUIDsPassThroughUnchanged() {
        let existing = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        XCTAssertEqual(
            StableIdentifier.uuid(fromPossibleUUID: existing).uuidString.uppercased(),
            existing
        )
    }

    func testDerivedIdentifierIsAWellFormedV5UUID() {
        let uuid = StableIdentifier.uuid(from: "irgendwas")
        let string = uuid.uuidString
        XCTAssertEqual(string.count, 36)
        // Version nibble, then RFC 4122 variant.
        let version = string[string.index(string.startIndex, offsetBy: 14)]
        XCTAssertEqual(version, "5")
        let variant = string[string.index(string.startIndex, offsetBy: 19)]
        XCTAssertTrue("89ABab".contains(variant), "variant nibble was \(variant)")
    }

    /// Two previewed browser apps must land in separate cookie jars.
    func testPreviewAppsGetDistinctSessionStores() {
        let a = MiniAppRunnerView.sessionStoreID(for: MiniAppConsent.previewId(html: "<html>A</html>"))
        let b = MiniAppRunnerView.sessionStoreID(for: MiniAppConsent.previewId(html: "<html>B</html>"))
        XCTAssertNotEqual(a, b, "different preview apps must not share a session store")
    }
}

/// The mini-app open-target is model-authored, so it goes through the same
/// gate as any other model-chosen URL.
final class OpenTargetValidationTests: XCTestCase {
    func testPrivateTargetsAreNotDirectlyLoadable() {
        for raw in ["http://127.0.0.1:8080/", "http://192.168.1.10/admin", "http://100.64.0.1:8090/"] {
            let html = "<!-- capability: browser --><!-- open: \(raw) -->"
            let target = WebAppBuilder.openTarget(in: html)
            XCTAssertNotNil(target, "parsing should succeed for \(raw)")
            XCTAssertFalse(
                NetworkTargetValidator.isAllowed(target!, allowPrivate: false),
                "a private address must not be directly loadable: \(raw)"
            )
        }
    }

    func testPublicTargetsRemainLoadable() {
        let html = WebAppBuilder.html(urlString: "x.com", name: "X")
        let target = WebAppBuilder.openTarget(in: html)!
        XCTAssertTrue(NetworkTargetValidator.isAllowed(target, allowPrivate: false))
    }

    func testMiniAppTargetRejectsEmptyAndExplicitPorts() {
        for raw in ["https://example.com:/", "https://example.com:443/", "https://example.com:8443/"] {
            XCTAssertFalse(
                NetworkTargetValidator.isAllowed(
                    URL(string: raw)!, allowPrivate: false, allowedHosts: ["example.com"]
                ),
                "mini-app target must refuse explicit port syntax in \(raw)"
            )
        }
    }

    func testHostNormalizationRejectsLeadingAndMalformedDots() {
        XCTAssertEqual(NetworkTargetValidator.normalizeHost("example.com."), "example.com")
        for raw in [".example.com", "..example.com", "example..com", "example.com.."] {
            XCTAssertNil(NetworkTargetValidator.normalizeHost(raw), "must reject \(raw)")
        }
    }
}

/// The transport rules the plan pulls into one place.
final class HTTPPolicyTests: XCTestCase {
    /// A streaming answer legitimately takes minutes; metadata must not.
    func testStreamingGetsFarMoreTimeThanMetadata() {
        XCTAssertGreaterThan(HTTPPolicy.streamingTimeout, HTTPPolicy.metadataTimeout * 10)
        XCTAssertGreaterThanOrEqual(HTTPPolicy.streamingTimeout, 600)
    }

    func testOnlyTransportFailuresAreRetriable() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let lost = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        XCTAssertTrue(HTTPPolicy.isRetriable(timeout))
        XCTAssertTrue(HTTPPolicy.isRetriable(lost))

        // A bad file, a bad model id, a full disk: retrying only hides the error.
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let badURL = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL)
        XCTAssertFalse(HTTPPolicy.isRetriable(cocoa))
        XCTAssertFalse(HTTPPolicy.isRetriable(badURL))
    }

    func testBackoffGrowsWithAttempts() {
        XCTAssertLessThan(HTTPPolicy.backoff(forAttempt: 1), HTTPPolicy.backoff(forAttempt: 3))
    }

    /// Cleartext is about WHO chose the address: the user's own LAN box, yes;
    /// a public host, never.
    func testCleartextOnlyForTheUsersOwnNetwork() {
        for raw in ["http://192.168.1.10:11434/v1", "http://127.0.0.1:8090", "http://100.64.0.1:8090"] {
            XCTAssertTrue(HTTPPolicy.allowsCleartext(for: URL(string: raw)!), raw)
            XCTAssertNil(HTTPPolicy.cleartextRefusal(for: URL(string: raw)!))
        }
        for raw in ["http://api.openai.com/v1", "http://example.com"] {
            XCTAssertFalse(HTTPPolicy.allowsCleartext(for: URL(string: raw)!), raw)
            XCTAssertNotNil(HTTPPolicy.cleartextRefusal(for: URL(string: raw)!))
        }
    }

    func testHTTPSIsAlwaysFine() {
        XCTAssertTrue(HTTPPolicy.allowsCleartext(for: URL(string: "https://api.openai.com/v1")!))
    }
}
