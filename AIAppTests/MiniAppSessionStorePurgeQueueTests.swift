import XCTest
@testable import AIApp

/// The durable list that makes "this cookie jar still has to go" survive the
/// process that failed to delete it. Its whole value is in the state machine
/// being one-way: an identifier WebKit has already accepted a removal for must
/// never walk back to "live jar", or WebKit's own leftover directory reads as a
/// user's site logins on every single launch.
///
/// Like the consent map, the queue lives in the shared `UserDefaults` of the
/// test host, so every test here snapshots and restores it.
final class MiniAppSessionStorePurgeQueueTests: XCTestCase {

    private var before: [MiniAppSessionStorePurgeQueue.Record] = []

    override func setUp() {
        super.setUp()
        before = MiniAppSessionStorePurgeQueue.records()
        MiniAppSessionStorePurgeQueue.removeAll()
    }

    override func tearDown() {
        MiniAppSessionStorePurgeQueue.replaceAll(before)
        before = []
        super.tearDown()
    }

    func testAnEmptyQueueOwesNothing() {
        XCTAssertTrue(MiniAppSessionStorePurgeQueue.isEmpty)
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.records(), [])
    }

    func testANotedIdentifierSurvivesAsPending() {
        let jar = UUID()
        MiniAppSessionStorePurgeQueue.note(jar, now: Date(timeIntervalSince1970: 770_000_000))
        let record = MiniAppSessionStorePurgeQueue.record(for: jar)
        XCTAssertEqual(record?.state, .pending)
        XCTAssertEqual(record?.attempts, 0)
        XCTAssertEqual(record?.firstNotedAt, Date(timeIntervalSince1970: 770_000_000))
    }

    /// Re-noting is what every launch does before retrying, so it must not reset
    /// the age — the age is how a stuck purge is recognised in a report.
    func testRenotingKeepsTheOriginalTimestampAndTheAttemptCount() {
        let jar = UUID()
        MiniAppSessionStorePurgeQueue.note(jar, now: Date(timeIntervalSince1970: 100))
        MiniAppSessionStorePurgeQueue.recordAttempt(jar, succeeded: false)
        MiniAppSessionStorePurgeQueue.note(jar, now: Date(timeIntervalSince1970: 900))

        let record = MiniAppSessionStorePurgeQueue.record(for: jar)
        XCTAssertEqual(record?.firstNotedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(record?.attempts, 1)
        XCTAssertEqual(record?.state, .pending, "a refusal leaves it exactly where it was")
    }

    func testAFailedAttemptCountsAndStaysPending() {
        let jar = UUID()
        MiniAppSessionStorePurgeQueue.note(jar)
        MiniAppSessionStorePurgeQueue.recordAttempt(jar, succeeded: false)
        MiniAppSessionStorePurgeQueue.recordAttempt(jar, succeeded: false)
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.record(for: jar)?.attempts, 2)
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.record(for: jar)?.state, .pending)
    }

    /// The one-way walk: accepted once, tombstoned from then on.
    func testAnAcceptedRemovalTombstonesTheIdentifier() {
        let jar = UUID()
        MiniAppSessionStorePurgeQueue.note(jar)
        MiniAppSessionStorePurgeQueue.recordAttempt(jar, succeeded: true)
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.record(for: jar)?.state, .residual)

        // A later refusal of the leftover directory must not turn it back into a
        // jar: nothing of the user's is in it any more.
        MiniAppSessionStorePurgeQueue.recordAttempt(jar, succeeded: false)
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.record(for: jar)?.state, .residual)
        MiniAppSessionStorePurgeQueue.note(jar)
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.record(for: jar)?.state, .residual)
    }

    func testForgettingRemovesOnlyThatIdentifier() {
        let kept = UUID()
        let dropped = UUID()
        MiniAppSessionStorePurgeQueue.note(kept)
        MiniAppSessionStorePurgeQueue.note(dropped)
        MiniAppSessionStorePurgeQueue.forget(dropped)
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.records().map(\.identifier), [kept])
    }

    /// Oldest first, and stable — a report that reshuffles between launches is
    /// unreadable, and the oldest entry is the interesting one.
    func testRecordsComeBackOldestFirst() {
        let first = UUID()
        let second = UUID()
        MiniAppSessionStorePurgeQueue.note(second, now: Date(timeIntervalSince1970: 2_000))
        MiniAppSessionStorePurgeQueue.note(first, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(MiniAppSessionStorePurgeQueue.records().map(\.identifier), [first, second])
    }

    /// The list is bounded, and it keeps the OLDEST entries: those are the ones
    /// that have already refused to go. Losing a newer one costs little — while
    /// any browser grant exists the sweep re-discovers unowned jars by
    /// enumerating them anyway.
    func testTheQueueIsBoundedAndKeepsTheOldestEntries() {
        let overflow = MiniAppSessionStorePurgeQueue.maximumEntries + 10
        for index in 0..<overflow {
            MiniAppSessionStorePurgeQueue.note(UUID(),
                                               now: Date(timeIntervalSince1970: Double(index)))
        }
        let records = MiniAppSessionStorePurgeQueue.records()
        XCTAssertEqual(records.count, MiniAppSessionStorePurgeQueue.maximumEntries)
        XCTAssertEqual(records.first?.firstNotedAt, Date(timeIntervalSince1970: 0))
    }

    func testTheQueueSurvivesAReadFromScratch() {
        let jar = UUID()
        MiniAppSessionStorePurgeQueue.note(jar, now: Date(timeIntervalSince1970: 42))
        MiniAppSessionStorePurgeQueue.recordAttempt(jar, succeeded: false)
        // Nothing cached in memory: a fresh read is what the next launch does.
        XCTAssertEqual(
            MiniAppSessionStorePurgeQueue.records(),
            [MiniAppSessionStorePurgeQueue.Record(
                identifier: jar, state: .pending,
                firstNotedAt: Date(timeIntervalSince1970: 42), attempts: 1
            )]
        )
    }
}
