import XCTest
@testable import AIApp

/// Issue D: the curated pool, the seeded sampler and the ONE composition rule
/// that the chat empty state reads.
final class ChatSuggestionsTests: XCTestCase {

    // MARK: - Pool

    func testPoolIsLargeUniqueAndChipSized() {
        let pool = ChatSuggestions.buildPool
        XCTAssertGreaterThanOrEqual(pool.count, 12, "the point of the pool is that it is bigger than the row")
        XCTAssertEqual(Set(pool.map(ChatSuggestions.normalizedKey)).count, pool.count, "pool has near-duplicates")
        for item in pool {
            XCTAssertFalse(item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertLessThanOrEqual(item.count, 24, "\(item) will be truncated in a one-line capsule")
        }
    }

    // MARK: - Seeded sampling

    func testSameSeedGivesSameSet() {
        let first = ChatSuggestions.sample(seed: 42)
        let second = ChatSuggestions.sample(seed: 42)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, ChatSuggestions.sample(seed: 42), "sampling must not carry state between calls")
    }

    func testDifferentSeedsGiveDifferentSets() {
        let sets = (0..<12).map { Set(ChatSuggestions.sample(seed: UInt64($0))) }
        XCTAssertGreaterThan(Set(sets.map { $0.sorted().joined(separator: "|") }).count, 3,
                             "seeds barely vary the sample")
    }

    func testSampleCountAndMembership() {
        let sample = ChatSuggestions.sample(seed: 9)
        XCTAssertEqual(sample.count, ChatSuggestions.slotCount)
        XCTAssertEqual(Set(sample).count, sample.count, "a chip must never appear twice")
        for item in sample { XCTAssertTrue(ChatSuggestions.buildPool.contains(item)) }
    }

    func testThreadSeedIsStablePerIdAndDiffersAcrossIds() {
        let id = UUID()
        XCTAssertEqual(ChatSuggestions.seed(for: id), ChatSuggestions.seed(for: id))
        let seeds = Set((0..<50).map { _ in ChatSuggestions.seed(for: UUID()) })
        XCTAssertGreaterThan(seeds.count, 45, "thread seeds collide far too often")
    }

    // MARK: - No immediate repeat

    func testExcludedSetIsNotShownAgain() {
        let previous = ChatSuggestions.sample(seed: 1)
        let next = ChatSuggestions.sample(seed: 2, excluding: Set(previous))
        XCTAssertTrue(Set(next).isDisjoint(with: Set(previous)), "a new chat reused the previous chips")
        XCTAssertEqual(next.count, ChatSuggestions.slotCount)
    }

    func testExclusionIsCaseAndPunctuationInsensitive() {
        let next = ChatSuggestions.sample(seed: 3, excluding: ["todo liste", "TRINKGELD RECHNER"])
        XCTAssertFalse(next.contains("Todo-Liste"))
        XCTAssertFalse(next.contains("Trinkgeld-Rechner"))
    }

    func testDegradesInsteadOfStarvingWhenAlmostEverythingIsExcluded() {
        let pool = ["A", "B", "C", "D", "E"]
        let sample = ChatSuggestions.sample(
            count: 4, seed: 5, excluding: ["A", "B", "C", "D"], from: pool
        )
        XCTAssertEqual(sample.count, 4, "showing a repeat beats showing one chip")
        XCTAssertEqual(Set(sample).count, 4)
        XCTAssertTrue(Set(sample).isSubset(of: Set(pool)))
    }

    // MARK: - Composition (D owns it, C only contributes)

    func testComposeIsAllStaticWithoutModelItems() {
        let composed = ChatSuggestions.compose(seed: 11)
        XCTAssertEqual(composed, ChatSuggestions.sample(seed: 11))
    }

    func testModelItemsLeadAndPoolPadsTheRest() {
        let composed = ChatSuggestions.compose(
            modelSuggestions: ["Schlaf-Tagebuch", "Farb-Picker"], seed: 12
        )
        XCTAssertEqual(composed.count, ChatSuggestions.slotCount)
        XCTAssertEqual(Array(composed.prefix(2)), ["Schlaf-Tagebuch", "Farb-Picker"])
        for padded in composed.dropFirst(2) {
            XCTAssertTrue(ChatSuggestions.buildPool.contains(padded))
        }
    }

    func testModelItemsAreCappedSoTheRowIsNeverAllModel() {
        let composed = ChatSuggestions.compose(
            modelSuggestions: ["Eins", "Zwei", "Drei", "Vier", "Fünf"], seed: 13
        )
        XCTAssertEqual(composed.count, ChatSuggestions.slotCount)
        XCTAssertEqual(Array(composed.prefix(3)), ["Eins", "Zwei", "Drei"])
        XCTAssertTrue(ChatSuggestions.buildPool.contains(composed[3]), "the last slot stays curated")
    }

    func testCompositionDropsDuplicatesAndNearDuplicates() {
        let composed = ChatSuggestions.compose(
            modelSuggestions: ["Todo-Liste", "todo liste", "  ", "Wasser Tracker"], seed: 14
        )
        XCTAssertEqual(composed.count, ChatSuggestions.slotCount)
        XCTAssertEqual(Set(composed.map(ChatSuggestions.normalizedKey)).count, composed.count)
        XCTAssertFalse(composed.dropFirst(2).contains("Todo-Liste"),
                       "the pool re-offered an idea the model already proposed")
        XCTAssertFalse(composed.dropFirst(2).contains("Wasser-Tracker"),
                       "near-duplicate of a model idea landed in the same row")
    }

    func testCompositionIsDeterministicForTheSameSeed() {
        let a = ChatSuggestions.compose(modelSuggestions: ["Farb-Picker"], seed: 77)
        let b = ChatSuggestions.compose(modelSuggestions: ["Farb-Picker"], seed: 77)
        XCTAssertEqual(a, b)
    }

    // MARK: - Session level

    @MainActor
    func testNewThreadGetsAFullRowThatDiffersFromThePreviousOne() {
        let session = ChatSession()
        session.newThread()
        let first = session.emptyStateSuggestions
        XCTAssertEqual(first.count, ChatSuggestions.slotCount)

        session.newThread()
        let second = session.emptyStateSuggestions
        XCTAssertEqual(second.count, ChatSuggestions.slotCount)
        XCTAssertTrue(Set(second).isDisjoint(with: Set(first)),
                      "a fresh chat repeated the chips the last one showed")
    }

    @MainActor
    func testModelSuggestionsTakeTheLeadingSlotsOfTheSameRow() {
        let session = ChatSession()
        session.newThread()
        let staticRow = session.emptyStateSuggestions

        session.setModelSuggestionsForTesting(["Schlaf-Tagebuch", "Farb-Picker"])
        let mixed = session.emptyStateSuggestions
        XCTAssertEqual(mixed.count, ChatSuggestions.slotCount)
        XCTAssertEqual(Array(mixed.prefix(2)), ["Schlaf-Tagebuch", "Farb-Picker"])
        XCTAssertNotEqual(mixed, staticRow)

        // Losing the model ideas (provider switch, toggle off) restores a full
        // curated row rather than leaving a short one.
        session.setModelSuggestionsForTesting([])
        XCTAssertEqual(session.emptyStateSuggestions.count, ChatSuggestions.slotCount)
        for item in session.emptyStateSuggestions {
            XCTAssertTrue(ChatSuggestions.buildPool.contains(item))
        }
    }
}
