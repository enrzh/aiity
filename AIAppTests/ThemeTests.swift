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

    func testPressedScaleIsASubtleDip() {
        // A pressed card should dip, not shrink into a toy.
        XCTAssertGreaterThanOrEqual(Theme.pressedScale, 0.9)
        XCTAssertLessThan(Theme.pressedScale, 1.0)
    }

    func testStableHueIsDeterministicAndInRange() {
        XCTAssertEqual(Theme.stableHue("aiity"), Theme.stableHue("aiity"))
        for seed in ["", "aiity", "✨", "timer", "🧭compass", "checklist🌐"] {
            let hue = Theme.stableHue(seed)
            XCTAssertGreaterThanOrEqual(hue, 0)
            XCTAssertLessThan(hue, 1)
        }
    }

    func testTileHueIsQuantizedToTheCuratedPalette() {
        // Tile identity colors must come from the tuned palette, never from
        // an arbitrary point on the hue wheel — that was the "AI-built"
        // rainbow tell. Deterministic per seed, and the empty seed is valid.
        for seed in ["", "aiity", "✨", "timer", "🧭compass", "checklist🌐", "a", "b", "c"] {
            let hue = Theme.tileHue(for: seed)
            XCTAssertTrue(Theme.tileHues.contains(hue), "hue \(hue) for seed \(seed) is off-palette")
            XCTAssertEqual(hue, Theme.tileHue(for: seed))
        }
    }

    func testDarkTileToneIsDimmerButKeepsIdentity() {
        for deep in [false, true] {
            let light = Theme.tileTone(deep: deep, dark: false)
            let dark = Theme.tileTone(deep: deep, dark: true)
            // Dimmer on dark grids (the light pair glares there)…
            XCTAssertLessThan(dark.top, light.top)
            XCTAssertLessThan(dark.bottom, light.bottom)
            // …but never desaturated, so a tile keeps its color identity.
            XCTAssertGreaterThanOrEqual(dark.saturation, light.saturation)
            // Within the band that still reads as a colored tile, not a void.
            XCTAssertLessThanOrEqual(dark.top, 0.75)
            XCTAssertGreaterThanOrEqual(dark.bottom, 0.4)
        }
    }
}
