import XCTest
@testable import HeikoTranslate

/// GitHub #135, Phase 0. `RefereeEvidence` is the pure half of the
/// independent language witness — the part that runs at L1 and inside
/// `Tools/lidprobe.sh` on the same code the app would run.
///
/// These pin what the type is entitled to claim BEFORE the measurement
/// exists, which is the point of the phase: the structural rule (one
/// recognizer produced words, the other produced none), inertness whenever a
/// recognizer cannot testify, and the locale table. There is deliberately no
/// test of a confidence or length threshold, because there is deliberately no
/// threshold — see the #32 lesson quoted in the type's header.
final class RefereeEvidenceTests: XCTestCase {

    private typealias R = RefereeEvidence
    private typealias Reading = RefereeEvidence.Reading

    private func home(_ text: String, conf: Double = 0,
                      _ availability: R.Availability = .ready) -> Reading {
        Reading(lang: .de, availability: availability, text: text, confidence: conf)
    }

    private func partner(_ text: String, conf: Double = 0,
                         _ availability: R.Availability = .ready) -> Reading {
        Reading(lang: .es, availability: availability, text: text, confidence: conf)
    }

    // L1.95 — the one categorical case: exactly one recognizer heard words.
    // This is #125's shape, where the Gemini pair settles on a language in
    // NEITHER side of the pair and the referee's two recognizers cannot.
    func testL1_95_onlyOneRecognizerProducedWords() {
        XCTAssertEqual(R.verdict(home: home("Mir geht es gut"), partner: partner("")),
                       .spoke(.de))
        XCTAssertEqual(R.verdict(home: home(""), partner: partner("¿Dónde está la estación?")),
                       .spoke(.es))
    }

    // L1.95b — silence is not evidence for either side.
    func testL1_95b_neitherProducedWords() {
        guard case .inconclusive = R.verdict(home: home(""), partner: partner("")) else {
            return XCTFail("silence must not name a language")
        }
    }

    // L1.95c — both heard something: Phase 0 has NO answer, and must say so
    // rather than reach for the size ratio. The whole #32 revert was a
    // threshold fitted to two points; this is the same trap one phase earlier.
    func testL1_95c_bothProducedWordsIsInconclusive() {
        let v = R.verdict(home: home("Mir geht es gut", conf: 0.9),
                          partner: partner("me gusta", conf: 0.2))
        guard case .inconclusive = v else {
            return XCTFail("a calibrated discriminator is Phase 0's deliverable, not an assumption")
        }
    }

    // L1.95d — a recognizer that could not run cannot testify, even when a
    // stale transcript is attached. Inert, never fatal (R8).
    func testL1_95d_unavailableRecognizerCannotTestify() {
        for unavailable: R.Availability in [.noOnDeviceModel, .unauthorized, .failed("boom")] {
            let v = R.verdict(home: home("Mir geht es gut"),
                              partner: partner("", conf: 0, unavailable))
            guard case .inconclusive = v else {
                return XCTFail("\(unavailable) must make the referee inert, not decisive")
            }
        }
    }

    // L1.95e — whitespace is not words. A recognizer returning " \n" has
    // produced nothing, and must not win by default against a silent partner.
    func testL1_95e_whitespaceIsNotSubstantive() {
        XCTAssertFalse(home(" \n\t").isSubstantive)
        guard case .inconclusive = R.verdict(home: home(" \n\t"), partner: partner("")) else {
            return XCTFail("whitespace must not count as testimony")
        }
    }

    // L1.95f — the verdict can only ever name one of the two languages it was
    // given. A referee that can name a third language would reintroduce
    // exactly the #125 failure it exists to catch.
    func testL1_95f_verdictNamesOnlyThePair() {
        let cases: [(String, String)] = [("hallo", ""), ("", "hola"), ("hallo", "hola"), ("", "")]
        for (h, p) in cases {
            if case .spoke(let lang) = R.verdict(home: home(h), partner: partner(p)) {
                XCTAssertTrue([.de, .es].contains(lang), "named \(lang), which is not in the pair")
            }
        }
    }

    // L1.96 — the reported scores, which are the Phase 0 measurement itself.
    // Pinned so the lidprobe table means the same thing run to run.
    func testL1_96_scoresAreReportedNotThresholded() {
        let s = R.score(home: home("abcd", conf: 0.8), partner: partner("ab", conf: 0.3))
        XCTAssertEqual(s.homeChars, 4)
        XCTAssertEqual(s.partnerChars, 2)
        XCTAssertEqual(s.confidenceDelta, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s.lengthRatio, 0.5, accuracy: 0.0001)
        XCTAssertFalse(s.onlyOneSubstantive)
    }

    // L1.96b — an empty side collapses the ratio to 0 rather than dividing by
    // zero, and is the one case flagged as categorical.
    func testL1_96b_emptySideCollapsesTheRatio() {
        let s = R.score(home: home("abcd"), partner: partner(""))
        XCTAssertEqual(s.lengthRatio, 0)
        XCTAssertTrue(s.onlyOneSubstantive)
    }

    // L1.96c — swapping the sides negates the confidence delta and preserves
    // the ratio. The score must not privilege home; the app's home side is a
    // product decision, not an acoustic one.
    func testL1_96c_scoreIsSymmetric() {
        let a = R.score(home: home("abcd", conf: 0.8), partner: partner("ab", conf: 0.3))
        let b = R.score(home: Reading(lang: .es, text: "ab", confidence: 0.3),
                        partner: Reading(lang: .de, text: "abcd", confidence: 0.8))
        XCTAssertEqual(a.confidenceDelta, -b.confidenceDelta, accuracy: 0.0001)
        XCTAssertEqual(a.lengthRatio, b.lengthRatio, accuracy: 0.0001)
    }

    // L1.97 — every app language has a distinct recognition locale. The
    // switch is exhaustive, so a new Lang breaks the build rather than
    // shipping without a referee; this pins that none of them collide or
    // arrive empty.
    func testL1_97_everyLanguageHasADistinctLocale() {
        var seen = Set<String>()
        for lang in TurnLogic.Lang.allCases {
            let id = RefereeEvidence.speechLocaleIdentifier(for: lang)
            XCTAssertFalse(id.isEmpty, "\(lang) has no recognition locale")
            XCTAssertTrue(id.contains("-"), "\(lang): expected a language-REGION identifier, got \(id)")
            XCTAssertTrue(seen.insert(id).inserted, "\(id) is used by two languages")
        }
    }

    // L1.97b — the regional choices follow the app's own product decisions,
    // which the flags already encode: US English, Mexican Spanish.
    func testL1_97b_regionsMatchTheProductDecisions() {
        XCTAssertEqual(RefereeEvidence.speechLocaleIdentifier(for: .en), "en-US")
        XCTAssertEqual(RefereeEvidence.speechLocaleIdentifier(for: .es), "es-MX")
        XCTAssertEqual(RefereeEvidence.speechLocaleIdentifier(for: .de), "de-DE")
    }
}
