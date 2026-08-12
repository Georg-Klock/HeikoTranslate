import XCTest
@testable import HeikoTranslate

/// GitHub #29: the output-substance floors are per-language now, measured
/// rather than shared. These pin the measured entries the way L1.22/26/41
/// pin the German ones — with the loosen-only doctrine as an invariant over
/// every language, so no future entry can quietly make a script STRICTER
/// than the calibrated German baseline.
final class FloorsPerScriptTests: XCTestCase {

    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: s) }

    /// The TurnLogicTests settle shape: votes inside the window, one past it.
    private func settle(_ l: inout TurnLogic, _ code: String, at base: Date) {
        l.noteInputLanguage(code, from: l.partner, at: base)
        l.noteInputLanguage(code, from: l.partner, at: base.addingTimeInterval(0.5))
        l.noteInputLanguage(code, from: l.partner, at: base.addingTimeInterval(TurnLogic.settleWindow + 0.1))
    }

    // The doctrine as an invariant: measured entries may only LOOSEN.
    func testMeasuredEntriesOnlyLoosen() {
        let base = TurnLogic.germanBaselineFloors
        for lang in TurnLogic.Lang.allCases {
            let f = TurnLogic.floors(for: lang)
            XCTAssertLessThanOrEqual(f.decisive, base.decisive, "\(lang)")
            XCTAssertLessThanOrEqual(f.corroborated, base.corroborated, "\(lang)")
            XCTAssertLessThanOrEqual(f.ratio, base.ratio, "\(lang)")
        }
        // And the Latin homes keep the baseline exactly: their campaign
        // minima sit below it, but the binding constraint is the German
        // false-start corpus, which the campaign deliberately does not model.
        for lang in [TurnLogic.Lang.de, .en, .es, .fr] {
            XCTAssertEqual(TurnLogic.floors(for: lang).corroborated, base.corroborated, "\(lang)")
            XCTAssertEqual(TurnLogic.floors(for: lang).decisive, base.decisive, "\(lang)")
        }
    }

    // Shape coverage, deliberately labelled as such: with codes cleanly
    // settled foreign, the settled-codes route admits a short answer
    // REGARDLESS of the floors (the L1.26 doctrine) — verified by this
    // passing under the baseline too. What these two pin is that the dense-
    // script turn shapes flow through commit intact; the floors' own bite
    // is pinned by the decisive and ratio cases below, which fail-first.
    func testChineseShortAnswerCommitsUnderSettledForeignCodes() {
        var l = TurnLogic(home: .zh, partner: .de)
        settle(&l, "de", at: t(0))
        let echo = "Vielen Dank für alles."
        l.noteOutputs([.zh: "谢谢。"], inputs: [.de: echo], at: t(3))
        XCTAssertEqual(l.direction, .foreignSpoken,
                       "a real 3-char Chinese answer must survive the corroborated floor")
        XCTAssertEqual(l.translator, .zh)
        let bubble = l.commit(inputs: [.de: echo], outputs: [.zh: "谢谢。"])
        XCTAssertEqual(bubble?.isHome, false)
        XCTAssertEqual(bubble?.translation, "谢谢。")
    }

    // The Korean mirror: "네." (2 chars) beside a long echo, codes settled
    // foreign — at the measured floor exactly.
    func testKoreanShortAnswerCommitsUnderSettledForeignCodes() {
        var l = TurnLogic(home: .ko, partner: .de)
        settle(&l, "de", at: t(0))
        let echo = "Ist das für Sie in Ordnung?"
        l.noteOutputs([.ko: "네."], inputs: [.de: echo], at: t(3))
        XCTAssertEqual(l.direction, .foreignSpoken)
        let bubble = l.commit(inputs: [.de: echo], outputs: [.ko: "네."])
        XCTAssertEqual(bubble?.isHome, false)
    }

    // The RATIO floor, in the shape where it decides SIDES (the L1.20
    // doctrine: session behaviour beats lying codes — but only if the
    // output READS as a real translation, which is the ratio's call).
    // A 7-char Chinese translation against a 22-char German echo is 0.32:
    // under the baseline 0.4 it is "not a translation", the lying home
    // codes win, and the turn lands as Heiko's own words — the wrong-side
    // class. Under the measured zh floor (0.23) the translation counts and
    // the turn lands LEFT, translated by the home session.
    func testRatioFloorPerScriptBeatsLyingCodes() {
        var l = TurnLogic(home: .zh, partner: .de)
        settleFromBoth(&l, "zh", at: t(0))   // the codes LIE toward home
        let echo = "Vielen Dank für alles."
        l.noteOutputs([.zh: "非常感谢一切。"], inputs: [.de: echo], at: t(3))
        XCTAssertEqual(l.direction, .foreignSpoken,
                       "a genuine dense-script translation must beat lying codes, as German's does (L1.20)")
        XCTAssertEqual(l.translator, .zh)
    }

    /// Codes from BOTH sessions, so no crossed shape forms — the pure
    /// L1.20 configuration.
    private func settleFromBoth(_ l: inout TurnLogic, _ code: String, at base: Date) {
        l.noteInputLanguage(code, from: l.home, at: base)
        l.noteInputLanguage(code, from: l.partner, at: base.addingTimeInterval(0.5))
        l.noteInputLanguage(code, from: l.home, at: base.addingTimeInterval(TurnLogic.settleWindow + 0.1))
    }

    // The DECISIVE floor, where the gate actually lives (the L1.26b shape:
    // no codes, no echo — the home output must stand entirely on its own).
    // One character stays a false start even in the densest script;
    // a three-character real answer now stands, which the German-calibrated
    // 8 rejected — the other half of #29's defect.
    func testDecisiveFloorPerScript() {
        var oneChar = TurnLogic(home: .zh, partner: .de)
        oneChar.noteOutputs([.zh: "好"], inputs: [:], at: t(0))
        XCTAssertNil(oneChar.direction, "one character alone proves nothing, loosened is not gone")

        var shortAnswer = TurnLogic(home: .zh, partner: .de)
        shortAnswer.noteOutputs([.zh: "好的。"], inputs: [:], at: t(0))
        XCTAssertEqual(shortAnswer.direction, .foreignSpoken,
                       "3 chars meets the measured zh decisive floor — the baseline 8 swallowed it")
    }
}
