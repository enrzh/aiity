import XCTest
@testable import AIApp

final class StreamingTextBufferTests: XCTestCase {
    func testSmallDeltasAreCoalescedUntilTheIntervalElapses() {
        var buffer = StreamingTextBuffer(interval: 0.05, characterThreshold: 200)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(buffer.append("Hel", at: start))
        XCTAssertNil(buffer.append("lo", at: start.addingTimeInterval(0.02)))
        XCTAssertEqual(buffer.append("!", at: start.addingTimeInterval(0.1)), "Hello!")
    }

    func testLargeBurstsFlushWithoutWaitingForTheTimer() {
        var buffer = StreamingTextBuffer(interval: 1, characterThreshold: 5)
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(buffer.append("1234", at: now))
        XCTAssertEqual(buffer.append("56", at: now), "123456")
    }

    func testFlushReturnsTheFinalPartialChunkExactlyOnce() {
        var buffer = StreamingTextBuffer(interval: 1, characterThreshold: 200)

        XCTAssertNil(buffer.append("final", at: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(buffer.flush(), "final")
        XCTAssertNil(buffer.flush())
    }

    func testAnEmptyDeltaNeverPublishes() {
        var buffer = StreamingTextBuffer(interval: 0, characterThreshold: 1)

        XCTAssertNil(buffer.append("", at: Date(timeIntervalSince1970: 1_000)))
        XCTAssertNil(buffer.flush())
    }

    func testTokenScaleStreamProducesBoundedPublicationsWithoutLosingText() {
        var buffer = StreamingTextBuffer(interval: 1, characterThreshold: 200)
        let now = Date(timeIntervalSince1970: 1_000)
        var published: [String] = []

        for _ in 0..<10_000 {
            if let chunk = buffer.append("x", at: now) {
                published.append(chunk)
            }
        }
        if let tail = buffer.flush() { published.append(tail) }

        XCTAssertEqual(published.joined().count, 10_000)
        XCTAssertLessThanOrEqual(published.count, 50)
    }
}
