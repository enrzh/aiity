import Foundation
import Network

/// Minimal in-process HTTP/1.1 stub backing the full `ConnectionProbe.test`
/// unit tests. It speaks the same provider shapes as `tools/stub_llm_server.py`
/// (OpenAI-compat models + chat, Anthropic models + messages, native-Ollama
/// tags, and error servers) but lives inside the test process on an ephemeral
/// loopback port — the unit suite stays hermetic: no external Python process,
/// and no fixed port that could collide with a UI-test stub running on 8555.
final class ProbeStubServer {

    enum Mode {
        /// GET /v1/models (OpenAI shape) + POST …/chat/completions.
        case openai
        /// GET /v1/models (Anthropic shape) + POST …/v1/messages.
        case anthropic
        /// GET /api/tags only; /v1/models answers 404 (like native Ollama,
        /// which still serves OpenAI-compat chat under /v1).
        case ollamaNative
        /// Every route answers 401 with an error body.
        case unauthorized
        /// Every route answers 404.
        case notFound
        /// Redirects every route to the provided URL.
        case redirect(URL)
        /// Image generation: one scripted answer shape (see `ImageScenario`).
        /// Mirrors the scenarios `tools/stub_llm_server.py` serves under
        /// `/v1/images/generations?scenario=…`.
        case images(ImageScenario)
    }

    /// The answer shapes real providers have been seen to give.
    enum ImageScenario: String {
        /// `{"data":[{"b64_json":"<png>"}]}` — OpenAI gpt-image-1.
        case base64
        /// base64 wrapped as a `data:` URI with newlines — gateway style.
        case base64DataURI
        /// `{"data":[{"url":"http://…/generated.png"}]}` — dall-e.
        case url
        /// A `url` answer whose link 403s (expired).
        case urlExpired
        /// `{"data":[]}` — well-formed, no image.
        case emptyData
        /// 400 with a provider error envelope.
        case badRequest
        /// 400 content-policy refusal.
        case contentPolicy
        /// 404 on /images (OpenRouter) + an image on /chat/completions.
        case chatCompletionsOnly
        /// Chat wire that answers with words instead of a picture.
        case chatRefusal
        /// 401 on every route.
        case unauthorized
        /// 429 rate limit.
        case rateLimited
        /// 400 that names `size`; succeeds once `size` is dropped.
        case rejectsSizeParameter
    }

    /// 1x1 transparent PNG.
    static let tinyPNGBase64 = """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
    """
    static var tinyPNG: Data { Data(base64Encoded: tinyPNGBase64)! }

    /// Request bodies the server has seen, for assertions (e.g. "the retry
    /// dropped `size`"). Guarded — they are appended on the listener queue.
    private var receivedBodies: [String] = []
    private let bodyLock = NSLock()
    private var receivedRequestCount = 0

    var requestCount: Int {
        bodyLock.lock()
        defer { bodyLock.unlock() }
        return receivedRequestCount
    }

    struct StartupError: Error {}

    let mode: Mode
    private let listener: NWListener
    private let queue = DispatchQueue(label: "probe-stub-server")
    private var connections: [NWConnection] = []

    private(set) var port: UInt16 = 0
    /// e.g. "http://127.0.0.1:PORT" — hand this to `ProviderSettings.baseURL`.
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(mode: Mode) throws {
        self.mode = mode
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            listener.cancel()
            throw StartupError()
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.cancel()
        queue.async { [weak self] in
            self?.connections.forEach { $0.cancel() }
            self?.connections.removeAll()
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if let request = Self.parseRequest(buffer) {
                self.bodyLock.lock()
                self.receivedRequestCount += 1
                if !request.body.isEmpty {
                    self.receivedBodies.append(request.body)
                }
                self.bodyLock.unlock()
                self.respond(connection, method: request.method, path: request.path)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffered: buffer)
        }
    }

    /// nil while the request (headers + Content-Length body) is incomplete.
    private static func parseRequest(_ data: Data) -> (method: String, path: String, body: String)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            if pieces.count == 2,
               pieces[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pieces[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyReceived = data.distance(from: headerEnd.upperBound, to: data.endIndex)
        guard bodyReceived >= contentLength else { return nil }
        let body = String(decoding: data[headerEnd.upperBound...], as: UTF8.self)
        return (String(parts[0]), String(parts[1]), body)
    }

    private func respond(_ connection: NWConnection, method: String, path: String) {
        if case .redirect(let target) = mode {
            let head = "HTTP/1.1 302 Found\r\nLocation: \(target.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let (status, body, contentType) = route(method: method, path: path)
        var head = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        default: return "Status"
        }
    }

    // MARK: - Routes (same shapes as tools/stub_llm_server.py)

    private func route(method: String, path: String) -> (Int, Data, String) {
        func json(_ text: String) -> Data { Data(text.utf8) }
        let miss = (404, json(#"{"error":{"message":"not found"}}"#), "application/json")

        switch mode {
        case .unauthorized:
            return (401, json(#"{"error":{"message":"invalid api key"}}"#), "application/json")
        case .notFound:
            return miss
        case .redirect:
            return miss
        case .images(let scenario):
            return imageRoute(scenario: scenario, method: method, path: path)
        case .openai:
            if method == "GET", path.hasPrefix("/v1/models") || path.hasSuffix("/models") {
                return (200, json(#"{"data":[{"id":"stub-large","object":"model"},{"id":"stub-mini","object":"model"}]}"#), "application/json")
            }
            if method == "POST", path.hasSuffix("/chat/completions") {
                return (200, json(#"{"id":"chatcmpl-stub","object":"chat.completion","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"ok"}}]}"#), "application/json")
            }
        case .anthropic:
            if method == "GET", path.hasPrefix("/v1/models") {
                return (200, json(#"{"data":[{"type":"model","id":"claude-stub-1","display_name":"Claude Stub"}],"has_more":false}"#), "application/json")
            }
            if method == "POST", path.hasSuffix("/messages") {
                return (200, json(#"{"id":"msg_stub","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#), "application/json")
            }
        case .ollamaNative:
            if method == "GET", path.hasPrefix("/api/tags") {
                return (200, json(#"{"models":[{"name":"qwen2.5:0.5b","model":"qwen2.5:0.5b"}]}"#), "application/json")
            }
            if method == "POST", path.hasSuffix("/chat/completions") {
                return (200, json(#"{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"ok"}}]}"#), "application/json")
            }
        }
        return miss
    }

    // MARK: - Image generation scenarios

    /// `GET /generated.png` serves the bytes for the `url` scenarios; every
    /// other path is the generation endpoint itself.
    private func imageRoute(scenario: ImageScenario, method: String, path: String) -> (Int, Data, String) {
        func json(_ text: String) -> Data { Data(text.utf8) }
        let png = Self.tinyPNG
        let b64 = Self.tinyPNGBase64
        let imagesPath = path.contains("/images/generations")
        let chatPath = path.contains("/chat/completions")

        if path.contains("/generated.png") {
            if scenario == .urlExpired {
                return (403, Data("<html><body>Link expired</body></html>".utf8), "text/html")
            }
            return (200, png, "image/png")
        }

        switch scenario {
        case .base64:
            guard imagesPath else { return (404, json(#"{"error":{"message":"not found"}}"#), "application/json") }
            return (200, json(#"{"created":1,"data":[{"b64_json":"\#(b64)","revised_prompt":"a red cat"}]}"#), "application/json")

        case .base64DataURI:
            guard imagesPath else { return (404, json(#"{"error":{"message":"not found"}}"#), "application/json") }
            // Wrapped at 40 chars with a data: prefix — both of which the old
            // strict `Data(base64Encoded:)` refused.
            let wrapped = stride(from: 0, to: b64.count, by: 40).map { offset -> String in
                let start = b64.index(b64.startIndex, offsetBy: offset)
                let end = b64.index(start, offsetBy: min(40, b64.count - offset))
                return String(b64[start..<end])
            }.joined(separator: "\\n")
            return (200, json(#"{"data":[{"b64_json":"data:image/png;base64,\#(wrapped)"}]}"#), "application/json")

        case .url, .urlExpired:
            guard imagesPath else { return (404, json(#"{"error":{"message":"not found"}}"#), "application/json") }
            return (200, json(#"{"data":[{"url":"http://127.0.0.1:\#(port)/generated.png"}]}"#), "application/json")

        case .emptyData:
            return (200, json(#"{"created":1,"data":[]}"#), "application/json")

        case .badRequest:
            return (400, json(#"{"error":{"message":"Invalid value for 'quality'","type":"invalid_request_error","param":"quality","code":null}}"#), "application/json")

        case .contentPolicy:
            return (400, json(#"{"error":{"message":"Your request was rejected as a result of our safety system.","type":"image_generation_user_error","code":"content_policy_violation"}}"#), "application/json")

        case .chatCompletionsOnly:
            if imagesPath {
                return (404, json(#"{"error":{"message":"No endpoints found for images/generations","code":404}}"#), "application/json")
            }
            if chatPath {
                return (200, json(#"{"id":"gen-1","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Hier ist es.","images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(b64)"}}]}}]}"#), "application/json")
            }
            return (404, json(#"{"error":{"message":"not found"}}"#), "application/json")

        case .chatRefusal:
            if imagesPath {
                return (404, json(#"{"error":{"message":"No endpoints found"}}"#), "application/json")
            }
            return (200, json(#"{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Ich kann keine Bilder erzeugen."}}]}"#), "application/json")

        case .unauthorized:
            return (401, json(#"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#), "application/json")

        case .rateLimited:
            return (429, json(#"{"error":{"message":"Rate limit exceeded","type":"requests"}}"#), "application/json")

        case .rejectsSizeParameter:
            let sentSize = lastBody().contains("\"size\"")
            if sentSize {
                return (400, json(#"{"error":{"message":"Unsupported parameter: 'size' is not supported with this model.","param":"size"}}"#), "application/json")
            }
            return (200, json(#"{"data":[{"b64_json":"\#(b64)"}]}"#), "application/json")
        }
    }

    func lastBody() -> String {
        bodyLock.lock()
        defer { bodyLock.unlock() }
        return receivedBodies.last ?? ""
    }

    func bodies() -> [String] {
        bodyLock.lock()
        defer { bodyLock.unlock() }
        return receivedBodies
    }
}
