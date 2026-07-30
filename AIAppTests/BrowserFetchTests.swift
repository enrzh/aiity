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
