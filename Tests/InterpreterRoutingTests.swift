import XCTest
@testable import HeikoTranslate

/// GitHub #135, the interpreter experiment: one session picks the direction,
/// the app keeps segmentation. This is the seam between them — which side of
/// the pair the model just spoke in.
///
/// Why it must be right, and right *late* rather than early: the answer routes
/// the turn's translation and its held audio. A wrong side plays the
/// translation for the wrong speaker; a side chosen from a two-character
/// prefix is the false-start defect the shipping arbitration already learned
/// to refuse. Held audio costs nothing, so "not yet" is always safe and a
/// guess never is.
final class InterpreterRoutingTests: XCTestCase {

    // L1.105 — the answer for real translations, both directions.
    func testL1_105_identifiesTheSpokenSideOfThePair() {
        XCTAssertEqual(InterpreterRouting.side(of: "Je vais bien, merci.", home: .de, partner: .fr), .fr)
        XCTAssertEqual(InterpreterRouting.side(of: "Mir geht es gut, danke.", home: .de, partner: .fr), .de)
        XCTAssertEqual(InterpreterRouting.side(of: "Where is the train station?", home: .de, partner: .en), .en)
        XCTAssertEqual(InterpreterRouting.side(of: "Wo ist der Bahnhof, bitte?", home: .de, partner: .en), .de)
        XCTAssertEqual(InterpreterRouting.side(of: "¿Dónde está la estación?", home: .de, partner: .es), .es)
    }

    /// The pair restriction is the point. A third language must still resolve
    /// to one of the two, because the model was instructed to speak only
    /// those — an unconstrained classifier answering "Italian" would leave the
    /// turn with no side at all.
    func testL1_105a_answerIsAlwaysInsideTheConfiguredPair() {
        for text in ["Je vais bien, merci.", "Mir geht es gut, danke.", "Where is the station?"] {
            let side = InterpreterRouting.side(of: text, home: .de, partner: .fr)
            XCTAssertNotNil(side, text)
            XCTAssertTrue(side == .de || side == .fr, "\(text) → \(String(describing: side))")
        }
    }

    /// A prefix is not a language. The translation streams in, and locking the
    /// side to the first fragment is how a false start moves a bubble to the
    /// wrong speaker.
    func testL1_105b_refusesToJudgeTooLittleText() {
        XCTAssertNil(InterpreterRouting.side(of: "", home: .de, partner: .fr))
        XCTAssertNil(InterpreterRouting.side(of: "Je", home: .de, partner: .fr))
        XCTAssertNil(InterpreterRouting.side(of: "  ", home: .de, partner: .fr))
        XCTAssertLessThan("Je".count, InterpreterRouting.minimumCharacters)
    }

    /// A pair must be two languages. A misconfigured equal pair has no answer
    /// rather than an arbitrary one.
    func testL1_105c_degeneratePairHasNoSide() {
        XCTAssertNil(InterpreterRouting.side(of: "Mir geht es gut, danke.", home: .de, partner: .de))
    }

    /// Non-Latin scripts must work: the zh-home pair is a real configuration
    /// and its translations share no alphabet with the partner's.
    func testL1_105d_handlesNonLatinScripts() {
        XCTAssertEqual(InterpreterRouting.side(of: "这花费14欧元。", home: .zh, partner: .de), .zh)
        XCTAssertEqual(InterpreterRouting.side(of: "Das kostet 14 Euro.", home: .zh, partner: .de), .de)
        XCTAssertEqual(InterpreterRouting.side(of: "안녕하세요, 잘 지내세요?", home: .de, partner: .ko), .ko)
    }
}
