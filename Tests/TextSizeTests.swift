import SwiftUI
import XCTest
@testable import HeikoTranslate

/// GitHub #12: an untouched install used to force `.large` at the app root,
/// replacing the system Dynamic Type environment for every descendant — a
/// user who had chosen an accessibility text size in iOS was silently pushed
/// back to the app's default. The untouched state is now "no override": the
/// system size flows through, including the accessibility categories the
/// slider's seven notches cannot reach.
final class TextSizeTests: XCTestCase {

    // The untouched state applies NO override — that absence is the fix.
    func testSystemSentinelMeansNoOverride() {
        XCTAssertEqual(TextSize.defaultStep, TextSize.system,
                       "a fresh install must follow the system")
        XCTAssertNil(TextSize.override(for: TextSize.system),
                     "system means the environment flows through untouched")
    }

    // An explicit choice is an explicit override, for every notch.
    func testExplicitStepsOverride() {
        for (index, size) in TextSize.steps.enumerated() {
            XCTAssertEqual(TextSize.override(for: index), size)
        }
        // Out-of-range persisted values clamp instead of crashing — the
        // stored integer outlives any future change to the notch count.
        XCTAssertEqual(TextSize.override(for: 99), TextSize.steps.last)
        XCTAssertEqual(TextSize.override(for: -5), TextSize.steps.first)
    }

    // Where the thumb sits while the system is in charge: the nearest notch,
    // so the first drag starts from what the user already sees.
    func testNearestStepMapsSystemSizes() {
        XCTAssertEqual(TextSize.nearestStep(to: .large), 3)
        XCTAssertEqual(TextSize.nearestStep(to: .xSmall), 0)
        XCTAssertEqual(TextSize.nearestStep(to: .xxxLarge), 6)
        // The accessibility categories sit past the last notch and clamp to
        // it — the slider can START from there without being able to express
        // it, which is exactly why untouched must mean system.
        XCTAssertEqual(TextSize.nearestStep(to: .accessibility1), 6)
        XCTAssertEqual(TextSize.nearestStep(to: .accessibility5), 6)
    }
}
