import XCTest
@testable import HeikoTranslate

/// GitHub #14: VoiceOver used to meet ~500 duplicated wheel rows with no way
/// to learn or change the selection. Each column is one adjustable element
/// now, and its increment/decrement steps through the same displayed order
/// the wheel scrolls — these pin the two pure rules that adjustment rides.
///
/// What L1 deliberately does NOT cover, stated because the difference
/// matters (the L1.43 precedent): that VoiceOver actually surfaces exactly
/// one element per column with the right label and value. Those are
/// modifiers on a View, out of unit-test reach; closing that needs a
/// UI-test target, which remains the documented CI-spend decision.
final class AdjustableWheelTests: XCTestCase {

    /// A deterministic display order for the tests: raw code order.
    private func name(_ l: TurnLogic.Lang) -> String { l.rawValue }

    // The excluding column never offers the other side — the rule that
    // keeps an adjustment from silently colliding with the language the
    // user did not touch.
    func testExcludingColumnOmitsTheOtherSide() {
        let opts = LanguageColumn.selectableOptions(
            excludesOtherSide: true, otherSide: .de, displayName: name)
        XCTAssertFalse(opts.contains(.de))
        XCTAssertEqual(opts.count, TurnLogic.Lang.allCases.count - 1)

        let home = LanguageColumn.selectableOptions(
            excludesOtherSide: false, otherSide: .de, displayName: name)
        XCTAssertEqual(home.count,
                       TurnLogic.Lang.allCases.filter(\.canBeHome).count,
                       "the ME column offers every full app language — a collision there swaps, by design")
        XCTAssertTrue(home.allSatisfy(\.canBeHome),
                      "a partner-only language (#30) never reaches the home wheel")
    }

    // A full lap in each direction visits every option exactly once and
    // wraps — one notch of the endless wheel, as a swipe.
    func testAdjacentWalksFullLapsBothWays() {
        let opts = LanguageColumn.selectableOptions(
            excludesOtherSide: true, otherSide: .zh, displayName: name)
        var seen: [TurnLogic.Lang] = []
        var cur = opts[0]
        for _ in opts {
            seen.append(cur)
            cur = LanguageColumn.adjacent(cur, by: 1, in: opts)
        }
        XCTAssertEqual(Set(seen), Set(opts), "one lap visits every option once")
        XCTAssertEqual(cur, opts[0], "and lands back where it started")

        for _ in opts { cur = LanguageColumn.adjacent(cur, by: -1, in: opts) }
        XCTAssertEqual(cur, opts[0], "a decrement lap returns home too")
    }

    // An increment through the excluding column can never produce the other
    // side, whatever the starting point — the acceptance's "never leaves
    // home and partner equal", at the layer adjustment owns. (The binding
    // it writes is the same one touch uses, so the L1.29e swap invariant
    // covers the ME column's deliberate collisions.)
    func testAdjustNeverProducesTheExcludedLanguage() {
        for other in TurnLogic.Lang.allCases {
            let opts = LanguageColumn.selectableOptions(
                excludesOtherSide: true, otherSide: other, displayName: name)
            for start in opts {
                XCTAssertNotEqual(LanguageColumn.adjacent(start, by: 1, in: opts), other)
                XCTAssertNotEqual(LanguageColumn.adjacent(start, by: -1, in: opts), other)
            }
        }
    }

    // Degenerate inputs stay safe: an empty list returns the current pick,
    // and a selection not in the list (unreachable by invariant, but a
    // stored value outlives invariants) lands on the first option.
    func testDegenerateInputs() {
        XCTAssertEqual(LanguageColumn.adjacent(.de, by: 1, in: []), .de)
        let opts: [TurnLogic.Lang] = [.en, .es]
        XCTAssertEqual(LanguageColumn.adjacent(.de, by: 1, in: opts), .en)
    }
}
