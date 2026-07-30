import XCTest
@testable import AIApp

final class ThemeTests: XCTestCase {
    func testControlHeightMeetsAppleTouchTarget() {
        XCTAssertGreaterThanOrEqual(Theme.controlHeight, 44)
    }

    func testSpacingScaleIsStrictlyIncreasing() {
        XCTAssertLessThan(Theme.space1, Theme.space2)
        XCTAssertLessThan(Theme.space2, Theme.space3)
        XCTAssertLessThan(Theme.space3, Theme.space4)
    }

    func testCornerRadiusScaleIsStrictlyIncreasing() {
        XCTAssertLessThan(Theme.chipRadius, Theme.cardRadius)
        XCTAssertLessThan(Theme.cardRadius, Theme.bubbleRadius)
    }
}
