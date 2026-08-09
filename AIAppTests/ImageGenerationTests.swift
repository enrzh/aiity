import XCTest
@testable import AIApp

/// Everything about `generate_image`: whether the tool is offered at all
/// (gating), what is sent (wire + parameters), and what is understood coming
/// back (every response shape a provider has been seen to answer with).
///
/// The end-to-end cases run against `ProbeStubServer`, whose scenarios mirror
/// `tools/stub_llm_server.py`'s `/v1/images/generations?scenario=…`.
final class ImageGenerationTests: XCTestCase {

    // MARK: - Gating: never offer a tool that cannot work

    func testImageRouteNeedsProviderThatSupportsImages() {
        // Anthropic has no image endpoint at all — no route, no tool.
        var settings = ProviderSettings()
        settings.presetId = "anthropic"
        settings.imagePresetId = ""
        XCTAssertNil(MediaRoute.servingPresetId(modality: .image, from: settings))

        // An image slot pointed at a provider without image support is equally dead.
        settings.imagePresetId = "anthropic"
        XCTAssertNil(MediaRoute.servingPresetId(modality: .image, from: settings))

        // The chat provider is only borrowed when it can actually do images.
        settings.presetId = "openai"
        settings.imagePresetId = ""
        XCTAssertEqual(MediaRoute.servingPresetId(modality: .image, from: settings), "openai")
    }

    func testNoCredentialMeansNoImageTool() {
        // The core "offered but can never succeed" bug: a key-requiring
        // provider with no key used to resolve a route and 401 on every call.
        XCTAssertFalse(
            MediaCapability.canUseMedia(presetId: "openai", apiKey: "", modality: .image),
            "a provider that needs a key must not be offered without one"
        )
        XCTAssertFalse(
            MediaCapability.canUseMedia(presetId: "openai", apiKey: "   ", modality: .image)
        )
        XCTAssertFalse(
            MediaCapability.canUseMedia(presetId: "openai", apiKey: "oauth:", modality: .image),
            "an empty OAuth token is no credential either"
        )
        XCTAssertTrue(
            MediaCapability.canUseMedia(presetId: "openai", apiKey: "sk-test", modality: .image)
        )
        XCTAssertTrue(
            MediaCapability.canUseMedia(presetId: "openai", apiKey: "oauth:tok", modality: .image)
        )
    }

    func testLocalOnlyProvidersNeverGetTheImageTool() {
        // On-device MLX generates text only, and LAN runtimes don't serve /images.
        for presetId in ["mlx", "ollama", "lmstudio", "localai"] {
            XCTAssertFalse(
                MediaCapability.canUseMedia(presetId: presetId, apiKey: "whatever", modality: .image),
                "\(presetId) must not be an image route"
            )
        }
        var settings = ProviderSettings()
        settings.presetId = "mlx"
        settings.imagePresetId = "mlx"
        XCTAssertNil(MediaRoute.servingPresetId(modality: .image, from: settings))
        XCTAssertFalse(MediaRoute.canResolve(modality: .image, from: settings))
    }

    func testSystemPromptOnlyPromisesImagesWhenTheToolIsOffered() {
        var settings = ProviderSettings()
        settings.presetId = "openai"
        settings.model = "gpt-4.1"

        let without = ChatSession.buildSystemPrompt(
            settings: settings, editing: nil, userText: "hi", imageToolAvailable: false
        )
        XCTAssertFalse(without.contains("generate_image"),
                       "a model with no image tool must not be told it can draw")

        let with = ChatSession.buildSystemPrompt(
            settings: settings, editing: nil, userText: "hi", imageToolAvailable: true
        )
        XCTAssertTrue(with.contains("generate_image"))
    }

    func testLocalChatPromptNeverMentionsImageGeneration() {
        var settings = ProviderSettings()
        settings.presetId = "ollama"
        let prompt = ChatSession.buildSystemPrompt(
            settings: settings, editing: nil, userText: "mal mir ein bild", imageToolAvailable: true
        )
        XCTAssertFalse(prompt.contains("generate_image"),
                       "the local prompt has no tools section to hang it on")
    }

    // MARK: - Request shape

    func testOpenRouterUsesChatCompletionsWire() {
        // OpenRouter serves NO /images/generations — asking there is a flat 404,
        // and it is the app's default provider.
        XCTAssertEqual(
            ImageRequestBuilder.preferredWire(presetId: "openrouter", model: "google/gemini-2.5-flash-image"),
            .chatCompletions
        )
        for presetId in ["openai", "gemini", "xai", "sub2api", "custom-openai"] {
            XCTAssertEqual(
                ImageRequestBuilder.preferredWire(presetId: presetId, model: "gpt-image-1"),
                .imagesEndpoint,
                "\(presetId) speaks the /images endpoint"
            )
        }
        XCTAssertEqual(ImageWire.imagesEndpoint.alternative, .chatCompletions)
        XCTAssertEqual(ImageWire.chatCompletions.alternative, .imagesEndpoint)
    }

    func testChatWireBodyCarriesModalitiesAndNoSize() {
        let body = ImageRequestBuilder.body(
            wire: .chatCompletions, model: "m", prompt: "eine rote Katze", size: "1024x1024"
        )
        XCTAssertEqual(body["modalities"] as? [String], ["image", "text"])
        XCTAssertNil(body["size"], "the chat wire 400s on a size parameter")
        XCTAssertNil(ImageRequestBuilder.sanitizedSize("1024x1024", model: "m", wire: .chatCompletions))
    }

    func testSizeIsSanitizedPerModelFamily() {
        // dall-e-3 rejects the gpt-image-1 sizes outright; keep the aspect.
        XCTAssertEqual(
            ImageRequestBuilder.sanitizedSize("1024x1536", model: "dall-e-3", wire: .imagesEndpoint),
            "1024x1792"
        )
        XCTAssertEqual(
            ImageRequestBuilder.sanitizedSize("1536x1024", model: "dall-e-3", wire: .imagesEndpoint),
            "1792x1024"
        )
        // dall-e-2 is squares only.
        XCTAssertEqual(
            ImageRequestBuilder.sanitizedSize("1024x1536", model: "dall-e-2", wire: .imagesEndpoint),
            "1024x1024"
        )
        XCTAssertEqual(
            ImageRequestBuilder.sanitizedSize("512x512", model: "dall-e-2", wire: .imagesEndpoint),
            "512x512"
        )
        // Garbage from the model never reaches the provider.
        XCTAssertEqual(
            ImageRequestBuilder.sanitizedSize("groß", model: "gpt-image-1", wire: .imagesEndpoint),
            "1024x1024"
        )
        XCTAssertEqual(
            ImageRequestBuilder.sanitizedSize(nil, model: "gpt-image-1", wire: .imagesEndpoint),
            "1024x1024"
        )
        XCTAssertEqual(
            ImageRequestBuilder.sanitizedSize("1536x1024", model: "gpt-image-1", wire: .imagesEndpoint),
            "1536x1024"
        )
    }

    // MARK: - Response parsing

    private var pngBase64: String { ProbeStubServer.tinyPNGBase64 }

    func testParsesPlainBase64Response() {
        let body = Data(#"{"data":[{"b64_json":"\#(pngBase64)"}]}"#.utf8)
        guard case .bytes(let data) = ImageResponseParser.parse(status: 200, data: body, model: "m") else {
            return XCTFail("expected image bytes")
        }
        XCTAssertTrue(ImageResponseParser.looksLikeImage(data))
    }

    func testParsesDataURIAndWrappedBase64() {
        // Gateways hand back a full data: URI, sometimes newline-wrapped. The
        // old strict decoder returned nil for both and blamed the provider for
        // sending "keine nutzbaren Bilddaten".
        let wrapped = pngBase64.enumerated().map { index, character in
            index > 0 && index % 40 == 0 ? "\\n\(character)" : String(character)
        }.joined()
        let body = Data(#"{"data":[{"b64_json":"data:image/png;base64,\#(wrapped)"}]}"#.utf8)
        guard case .bytes = ImageResponseParser.parse(status: 200, data: body, model: "m") else {
            return XCTFail("data: URI + wrapped base64 must decode")
        }
        // URL-safe base64 without padding, too.
        let urlSafe = pngBase64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertNotNil(ImageResponseParser.decodeBase64Image(urlSafe))
    }

    func testParsesURLResponse() {
        let body = Data(#"{"data":[{"url":"https://cdn.example.com/img.png"}]}"#.utf8)
        guard case .remote(let url) = ImageResponseParser.parse(status: 200, data: body, model: "m") else {
            return XCTFail("expected a remote URL")
        }
        XCTAssertEqual(url.absoluteString, "https://cdn.example.com/img.png")
    }

    func testParsesChatCompletionsImageResponse() {
        let body = Data(#"""
        {"choices":[{"message":{"role":"assistant","content":"da","images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(pngBase64)"}}]}}]}
        """#.utf8)
        guard case .bytes = ImageResponseParser.parse(status: 200, data: body, model: "m") else {
            return XCTFail("the OpenRouter chat shape must be understood")
        }
    }

    func testEmptyDataArrayExplainsItself() {
        let body = Data(#"{"created":1,"data":[]}"#.utf8)
        guard case .failure(let failure) = ImageResponseParser.parse(status: 200, data: body, model: "gpt-4o") else {
            return XCTFail("an empty data array is a failure")
        }
        XCTAssertEqual(failure.kind, .emptyResult)
        XCTAssertTrue(failure.message.contains("gpt-4o"), "name the model that produced nothing")
        XCTAssertFalse(failure.isRetryable)
    }

    func testChatAnswerWithoutImageQuotesTheModel() {
        let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"Ich kann keine Bilder erzeugen."}}]}"#.utf8)
        guard case .failure(let failure) = ImageResponseParser.parse(status: 200, data: body, model: "m") else {
            return XCTFail("text instead of an image is a failure")
        }
        XCTAssertTrue(failure.message.contains("Ich kann keine Bilder erzeugen"))
    }

    func testProviderErrorBodyIsSurfacedInGerman() {
        let body = Data(#"{"error":{"message":"Invalid value for 'quality'","param":"quality"}}"#.utf8)
        guard case .failure(let failure) = ImageResponseParser.parse(status: 400, data: body, model: "gpt-image-1") else {
            return XCTFail("400 is a failure")
        }
        XCTAssertTrue(failure.message.contains("Invalid value for 'quality'"),
                      "the provider's own reason must reach the user")
        XCTAssertTrue(failure.message.contains("Bildgenerierung"))
    }

    func testContentPolicyRefusalIsRecognised() {
        let body = Data(#"{"error":{"message":"Your request was rejected as a result of our safety system.","code":"content_policy_violation"}}"#.utf8)
        guard case .failure(let failure) = ImageResponseParser.parse(status: 400, data: body, model: "gpt-image-1") else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(failure.kind, .contentPolicy)
        XCTAssertTrue(failure.message.contains("Inhaltsrichtlinie"))
        XCTAssertFalse(failure.isRetryable, "the same motif will be refused again")
    }

    func testAuthAndRateLimitGetTheirOwnAdvice() {
        let auth = ImageResponseParser.parse(
            status: 401, data: Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8), model: "m"
        )
        guard case .failure(let authFailure) = auth else { return XCTFail("expected failure") }
        XCTAssertEqual(authFailure.kind, .auth)
        XCTAssertTrue(authFailure.message.contains("API-Key"))

        let limited = ImageResponseParser.parse(
            status: 429, data: Data(#"{"error":{"message":"Rate limit"}}"#.utf8), model: "m"
        )
        guard case .failure(let limitFailure) = limited else { return XCTFail("expected failure") }
        XCTAssertEqual(limitFailure.kind, .rateLimit)
        XCTAssertTrue(limitFailure.isRetryable, "a rate limit is the one worth retrying")
    }

    func testMissingEndpointIsDistinctFromEverythingElse() {
        // This is what drives the fallback onto the other wire.
        let notFound = ImageResponseParser.parse(
            status: 404, data: Data(#"{"error":{"message":"No endpoints found"}}"#.utf8), model: "m"
        )
        guard case .failure(let failure) = notFound else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.kind, .unsupportedEndpoint)
    }

    func testNonImageBytesAreRejected() {
        // An expired image link that answers with an HTML error page used to be
        // stored as a "PNG" and reported to the model as a success.
        let html = Data("<html><body>gone</body></html>".utf8)
        XCTAssertFalse(ImageResponseParser.looksLikeImage(html))
        guard case .failure = ImageResponseParser.validateRemote(status: 200, data: html) else {
            return XCTFail("HTML is not an image")
        }
        guard case .failure(let expired) = ImageResponseParser.validateRemote(status: 403, data: Data()) else {
            return XCTFail("403 on the image URL is a failure")
        }
        XCTAssertTrue(expired.message.contains("403"))
        guard case .bytes = ImageResponseParser.validateRemote(status: 200, data: ProbeStubServer.tinyPNG) else {
            return XCTFail("a real PNG passes")
        }
    }

    func testGarbageBodyIsNotReportedAsSuccess() {
        let body = Data("<html>gateway timeout</html>".utf8)
        guard case .failure(let failure) = ImageResponseParser.parse(status: 200, data: body, model: "m") else {
            return XCTFail("non-JSON is a failure")
        }
        XCTAssertEqual(failure.kind, .undecodable)
    }

    // MARK: - End to end against the stub server

    private func route(_ server: ProbeStubServer, presetId: String = "openai", model: String = "gpt-image-1") -> MediaRoute {
        MediaRoute(presetId: presetId, baseURL: server.baseURL + "/v1", model: model, apiKey: "sk-test")
    }

    private func run(_ server: ProbeStubServer, presetId: String = "openai",
                     model: String = "gpt-image-1", size: String? = nil) async -> ToolRunResult {
        let tool = ImageGenerationTool(route: route(server, presetId: presetId, model: model))
        var args: [String: Any] = ["prompt": "eine rote Katze"]
        if let size { args["size"] = size }
        return await tool.run(argumentsJSON: String(decoding: jsonData(args), as: UTF8.self))
    }

    func testBase64ResponseStoresAndShowsTheImage() async throws {
        let server = try ProbeStubServer(mode: .images(.base64))
        defer { server.stop() }
        let result = await run(server)
        XCTAssertEqual(result.mediaIds.count, 1)
        XCTAssertTrue(result.text.contains("Bild erstellt"))
        let stored = try XCTUnwrap(MediaStore.imageData(for: try XCTUnwrap(result.mediaIds.first)))
        XCTAssertTrue(ImageResponseParser.looksLikeImage(stored))
        MediaStore.sweep(keeping: [], graceInterval: 0)
    }

    func testWrappedDataURIResponseAlsoStoresAnImage() async throws {
        let server = try ProbeStubServer(mode: .images(.base64DataURI))
        defer { server.stop() }
        let result = await run(server)
        XCTAssertEqual(result.mediaIds.count, 1, "wrapped data: URI must not fail: \(result.text)")
        MediaStore.sweep(keeping: [], graceInterval: 0)
    }

    func testURLResponseIsDownloadedAndStored() async throws {
        let server = try ProbeStubServer(mode: .images(.url))
        defer { server.stop() }
        let result = await run(server)
        XCTAssertEqual(result.mediaIds.count, 1, "url responses must be fetched: \(result.text)")
        MediaStore.sweep(keeping: [], graceInterval: 0)
    }

    func testExpiredImageURLFailsLoudlyInsteadOfStoringGarbage() async throws {
        let server = try ProbeStubServer(mode: .images(.urlExpired))
        defer { server.stop() }
        let result = await run(server)
        XCTAssertTrue(result.mediaIds.isEmpty, "nothing must be stored")
        XCTAssertTrue(result.text.contains("403") || result.text.contains("laden"),
                      "the user must learn why: \(result.text)")
    }

    func testEmptyDataArrayEndToEnd() async throws {
        let server = try ProbeStubServer(mode: .images(.emptyData))
        defer { server.stop() }
        let result = await run(server, model: "gpt-4o-mini")
        XCTAssertTrue(result.mediaIds.isEmpty)
        XCTAssertTrue(result.text.contains("kein Bild"), result.text)
        XCTAssertTrue(result.text.contains("nicht erneut"), "the model must be told to stop retrying")
    }

    func testProviderErrorEndToEnd() async throws {
        let server = try ProbeStubServer(mode: .images(.badRequest))
        defer { server.stop() }
        let result = await run(server)
        XCTAssertTrue(result.mediaIds.isEmpty)
        XCTAssertTrue(result.text.contains("quality"), result.text)
    }

    func testContentPolicyEndToEnd() async throws {
        let server = try ProbeStubServer(mode: .images(.contentPolicy))
        defer { server.stop() }
        let result = await run(server)
        XCTAssertTrue(result.text.contains("Inhaltsrichtlinie"), result.text)
    }

    func testUnauthorizedEndToEndTellsTheUserToFixTheKey() async throws {
        let server = try ProbeStubServer(mode: .images(.unauthorized))
        defer { server.stop() }
        let result = await run(server)
        XCTAssertTrue(result.text.contains("API-Key"), result.text)
    }

    func testRateLimitAllowsOneMoreAttempt() async throws {
        let server = try ProbeStubServer(mode: .images(.rateLimited))
        defer { server.stop() }
        let result = await run(server)
        XCTAssertTrue(result.text.contains("429") || result.text.contains("Rate-Limit"), result.text)
        XCTAssertFalse(result.text.contains("nicht erneut auf"),
                       "a rate limit is transient — don't forbid a retry")
    }

    func testOpenRouterStyleProviderFallsBackToChatCompletions() async throws {
        // /images 404s, /chat/completions returns the image: exactly OpenRouter.
        let server = try ProbeStubServer(mode: .images(.chatCompletionsOnly))
        defer { server.stop() }
        let result = await run(server, presetId: "openrouter", model: "google/gemini-2.5-flash-image")
        XCTAssertEqual(result.mediaIds.count, 1, "OpenRouter must generate images: \(result.text)")
        // It went straight to the chat wire — no wasted 404 round trip.
        XCTAssertEqual(server.bodies().count, 1)
        XCTAssertTrue(server.lastBody().contains("modalities"))
        MediaStore.sweep(keeping: [], graceInterval: 0)
    }

    func testUnknownGatewayRetriesOnTheOtherWire() async throws {
        // A preset we expect to serve /images, but which doesn't: one 404, then
        // the chat wire, then an image — rather than a dead end.
        let server = try ProbeStubServer(mode: .images(.chatCompletionsOnly))
        defer { server.stop() }
        let result = await run(server, presetId: "custom-openai", model: "some-image-model")
        XCTAssertEqual(result.mediaIds.count, 1, "the fallback wire must be tried: \(result.text)")
        XCTAssertEqual(server.bodies().count, 2, "exactly one fallback, not a loop")
        MediaStore.sweep(keeping: [], graceInterval: 0)
    }

    func testRefusedSizeParameterIsDroppedAndRetriedOnce() async throws {
        let server = try ProbeStubServer(mode: .images(.rejectsSizeParameter))
        defer { server.stop() }
        let result = await run(server, size: "1024x1536")
        XCTAssertEqual(result.mediaIds.count, 1, "should succeed without size: \(result.text)")
        XCTAssertEqual(server.bodies().count, 2)
        XCTAssertTrue(server.bodies()[0].contains("\"size\""))
        XCTAssertFalse(server.bodies()[1].contains("\"size\""))
        MediaStore.sweep(keeping: [], graceInterval: 0)
    }

    func testRepeatedHardFailuresStopCallingTheProvider() async throws {
        let server = try ProbeStubServer(mode: .images(.contentPolicy))
        defer { server.stop() }
        let tool = ImageGenerationTool(route: route(server))
        let arguments = #"{"prompt":"x"}"#
        _ = await tool.run(argumentsJSON: arguments)
        _ = await tool.run(argumentsJSON: arguments)
        let third = await tool.run(argumentsJSON: arguments)
        XCTAssertEqual(server.bodies().count, 2, "the third call must not hit the network")
        XCTAssertTrue(third.text.contains("mehrfach fehlgeschlagen"), third.text)
    }

    func testMissingBaseURLFailsWithSetupAdviceNotANetworkError() async {
        let tool = ImageGenerationTool(
            route: MediaRoute(presetId: "openai", baseURL: "", model: "gpt-image-1", apiKey: "sk")
        )
        let result = await tool.run(argumentsJSON: #"{"prompt":"x"}"#)
        XCTAssertTrue(result.text.contains("Verbindungen"), result.text)
        XCTAssertTrue(result.mediaIds.isEmpty)
    }

    func testEmptyPromptIsRejectedWithoutARequest() async throws {
        let server = try ProbeStubServer(mode: .images(.base64))
        defer { server.stop() }
        let tool = ImageGenerationTool(route: route(server))
        let result = await tool.run(argumentsJSON: #"{"prompt":"   "}"#)
        XCTAssertTrue(result.mediaIds.isEmpty)
        XCTAssertTrue(server.bodies().isEmpty)
    }

    // MARK: - Persistence

    func testGeneratedImageSurvivesTheThreadSnapshotRoundTrip() async throws {
        let server = try ProbeStubServer(mode: .images(.base64))
        defer { server.stop() }
        let result = await run(server)
        let mediaId = try XCTUnwrap(result.mediaIds.first)

        let message = ChatMessage(role: .assistant, text: "Hier ist dein Bild.", mediaIds: [mediaId])
        let thread = ChatThread(title: "Bild", messages: [message])
        let encoded = try JSONEncoder().encode([thread])
        let decoded = try JSONDecoder().decode([ChatThread].self, from: encoded)
        XCTAssertEqual(decoded.first?.messages.first?.mediaIds, [mediaId])
        // …and the bytes are still on disk under that id.
        XCTAssertNotNil(MediaStore.imageData(for: mediaId))
        // The sweep keeps what a live message references.
        MediaStore.sweep(keeping: [mediaId], graceInterval: 0)
        XCTAssertNotNil(MediaStore.imageData(for: mediaId))
        MediaStore.sweep(keeping: [], graceInterval: 0)
        XCTAssertNil(MediaStore.imageData(for: mediaId))
    }
}
