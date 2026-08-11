import XCTest
@testable import AIApp

final class ChatAttachmentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        MediaStore.directoryOverride = directory
    }

    override func tearDownWithError() throws {
        MediaStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testOldMessageWithoutAttachmentsStillDecodes() throws {
        let json = Data(#"{"role":"user","text":"Hallo"}"#.utf8)

        let message = try JSONDecoder().decode(ChatMessage.self, from: json)

        XCTAssertTrue(message.attachments.isEmpty)
    }

    func testAttachmentRoundTripPreservesIdentityAndMetadata() throws {
        let attachment = ChatAttachment(
            id: UUID(), mediaId: "photo.bin", filename: "photo.png",
            mimeType: "image/png", kind: .image
        )
        let message = ChatMessage(role: .user, text: "", attachments: [attachment])

        let decoded = try JSONDecoder().decode(
            ChatMessage.self,
            from: JSONEncoder().encode(message)
        )

        XCTAssertEqual(decoded.attachments, [attachment])
    }

    func testMediaStoreAtomicallyCopiesAttachmentBytes() throws {
        let source = directory.appendingPathComponent("source.png")
        let bytes = Data([0, 1, 2, 255])
        try bytes.write(to: source)

        let mediaId = try XCTUnwrap(
            MediaStore.save(data: try Data(contentsOf: source), filename: "photo.png", mimeType: "image/png")
        )

        XCTAssertEqual(try Data(contentsOf: MediaStore.url(for: mediaId)), bytes)
        XCTAssertNotEqual(mediaId, source.lastPathComponent)
    }

    func testMediaStoreReturnsNilWhenCopyCannotBeWritten() throws {
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        MediaStore.directoryOverride = blocker

        XCTAssertNil(MediaStore.save(data: Data("x".utf8), filename: "x.txt", mimeType: "text/plain"))
    }

    func testSweepKeepsReferencedAttachmentAndRemovesOrphan() throws {
        let kept = try XCTUnwrap(
            MediaStore.save(data: Data("kept".utf8), filename: "kept.txt", mimeType: "text/plain")
        )
        let orphan = try XCTUnwrap(
            MediaStore.save(data: Data("orphan".utf8), filename: "orphan.txt", mimeType: "text/plain")
        )

        MediaStore.sweep(keeping: [kept], graceInterval: -1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: MediaStore.url(for: kept).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: MediaStore.url(for: orphan).path))
    }

    func testOpenAIEncodesImageAttachmentAsDataPart() throws {
        let mediaId = try XCTUnwrap(
            MediaStore.save(data: Data([1, 2, 3]), filename: "photo.png", mimeType: "image/png")
        )
        let message = ChatMessage(
            role: .user,
            text: "Beschreibe das Bild",
            attachments: [ChatAttachment(mediaId: mediaId, filename: "photo.png", mimeType: "image/png", kind: .image)]
        )

        let encoded = try OpenAICompatibleProvider.encodeMessage(message)
        let parts = try XCTUnwrap(encoded["content"] as? [[String: Any]])
        let image = try XCTUnwrap(parts.last)

        XCTAssertEqual(image["type"] as? String, "image_url")
        XCTAssertEqual(
            (image["image_url"] as? [String: Any])?["url"] as? String,
            "data:image/png;base64,AQID"
        )
    }

    func testAnthropicEncodesImageAttachmentAsBase64Source() throws {
        let mediaId = try XCTUnwrap(
            MediaStore.save(data: Data([1, 2, 3]), filename: "photo.png", mimeType: "image/png")
        )
        let message = ChatMessage(
            role: .user,
            text: "Beschreibe das Bild",
            attachments: [ChatAttachment(mediaId: mediaId, filename: "photo.png", mimeType: "image/png", kind: .image)]
        )

        let encoded = try AnthropicProvider.encodeMessages([message])
        let parts = try XCTUnwrap(encoded.first?["content"] as? [[String: Any]])
        let image = try XCTUnwrap(parts.last)
        let source = try XCTUnwrap(image["source"] as? [String: Any])

        XCTAssertEqual(image["type"] as? String, "image")
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "AQID")
    }

    func testUnsupportedFileRemainsRepresentableAndReturnsLocalizedError() throws {
        let mediaId = try XCTUnwrap(
            MediaStore.save(data: Data("document".utf8), filename: "document.pdf", mimeType: "application/pdf")
        )
        let attachment = ChatAttachment(
            mediaId: mediaId, filename: "document.pdf", mimeType: "application/pdf", kind: .file
        )

        XCTAssertEqual(attachment.filename, "document.pdf")
        XCTAssertThrowsError(try OpenAICompatibleProvider.encodeMessage(
            ChatMessage(role: .user, text: "", attachments: [attachment])
        )) { error in
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.isEmpty ?? true)
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("document.pdf") ?? false)
        }
    }

    func testAnthropicUnsupportedFileReturnsLocalizedError() throws {
        let mediaId = try XCTUnwrap(
            MediaStore.save(data: Data("document".utf8), filename: "document.pdf", mimeType: "application/pdf")
        )
        let attachment = ChatAttachment(
            mediaId: mediaId, filename: "document.pdf", mimeType: "application/pdf", kind: .file
        )

        XCTAssertThrowsError(try AnthropicProvider.encodeMessages([
            ChatMessage(role: .user, text: "", attachments: [attachment])
        ])) { error in
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.isEmpty ?? true)
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("document.pdf") ?? false)
        }
    }

    func testMLXRejectsAttachmentsWithLocalizedError() async {
        let message = ChatMessage(
            role: .user,
            text: "Beschreibe den Anhang",
            attachments: [ChatAttachment(
                mediaId: "document.attachment",
                filename: "document.pdf",
                mimeType: "application/pdf",
                kind: .file
            )]
        )

        do {
            for try await _ in MLXProvider(modelId: "test").streamChat(messages: [message], tools: []) {
                XCTFail("MLX must reject attachments before streaming")
            }
            XCTFail("MLX must reject attachments")
        } catch let error as ProviderError {
            guard case .unsupportedAttachment(let filename) = error else {
                return XCTFail("Expected unsupportedAttachment, got \(error)")
            }
            XCTAssertEqual(filename, "document.pdf")
            XCTAssertTrue(error.localizedDescription.contains("document.pdf"))
        } catch {
            XCTFail("Expected ProviderError.unsupportedAttachment, got \(error)")
        }
    }

    func testPendingTurnRoundTripPreservesAttachments() throws {
        let attachment = ChatAttachment(
            mediaId: "photo.attachment",
            filename: "photo.png",
            mimeType: "image/png",
            kind: .image
        )
        let pending = PendingTurn(
            threadId: UUID(),
            userText: "Beschreibe das Bild",
            attachments: [attachment],
            turnStartIndex: 0,
            repairPasses: 0,
            startedAt: .now,
            updatedAt: .now,
            partialAssistantText: ""
        )

        let decoded = try JSONDecoder().decode(
            PendingTurn.self,
            from: JSONEncoder().encode(pending)
        )

        XCTAssertEqual(decoded.attachments, [attachment])
    }

    @MainActor
    func testDeterministicOpenURLShortcutRequiresAnAttachmentFreeTurn() {
        let attachment = ChatAttachment(
            mediaId: "photo.attachment",
            filename: "photo.png",
            mimeType: "image/png",
            kind: .image
        )

        XCTAssertTrue(
            ChatSession.shouldUseDeterministicOpenURLShortcut(
                text: "öffne example.com", attachments: [], isEditing: false
            )
        )
        XCTAssertFalse(
            ChatSession.shouldUseDeterministicOpenURLShortcut(
                text: "öffne example.com", attachments: [attachment], isEditing: false
            )
        )
        XCTAssertFalse(
            ChatSession.shouldUseDeterministicOpenURLShortcut(
                text: "öffne example.com", attachments: [], isEditing: true
            )
        )
    }

    func testAttachmentImportStateTracksPendingBatches() {
        var state = ChatAttachmentImportState()
        let token = state.beginBatch()

        XCTAssertTrue(state.isImporting)
        XCTAssertTrue(state.accepts(token))
        XCTAssertTrue(state.finish(token))
        XCTAssertFalse(state.isImporting)
        XCTAssertFalse(state.accepts(token))
    }

    func testAttachmentImportStateRejectsStaleCompletionAfterInvalidation() {
        var state = ChatAttachmentImportState()
        let oldToken = state.beginBatch()

        state.invalidate()

        XCTAssertFalse(state.isImporting)
        XCTAssertFalse(state.accepts(oldToken))
        XCTAssertFalse(state.finish(oldToken))

        let currentToken = state.beginBatch()
        XCTAssertNotEqual(oldToken.generation, currentToken.generation)
        XCTAssertTrue(state.accepts(currentToken))
    }

    func testCameraCapturesAppendAsDistinctImageAttachments() throws {
        let first = try XCTUnwrap(CameraAttachmentStore.saveJPEG(Data([1, 2, 3])))
        let second = try XCTUnwrap(CameraAttachmentStore.saveJPEG(Data([4, 5, 6])))

        XCTAssertNotEqual(first.mediaId, second.mediaId)
        XCTAssertEqual([first.kind, second.kind], [.image, .image])
        XCTAssertEqual(MediaStore.data(for: first.mediaId), Data([1, 2, 3]))
        XCTAssertEqual(MediaStore.data(for: second.mediaId), Data([4, 5, 6]))
    }
}
