import XCTest
@testable import HeikoTranslate

/// GitHub #32: a short German sentence opening with an English song title
/// commits to the FOREIGN side, with a German-into-German "translation".
///
/// The device log said only that `direction → home` never fired. That is
/// consistent with at least three mutually exclusive causes — the codes
/// settled on the partner so the veto barred home; the home session produced
/// a real translation of the English opening, which is read as proof of
/// foreign speech; or no plurality was reached inside the settle window —
/// and they want opposite fixes. `decisionSummary` exists to tell them apart
/// from a log.
///
/// These tests pin the diagnostic, not the decision. Nothing here asserts
/// what direction SHOULD be; they assert the log reports the state that
/// actually produced it, so the next device session is readable. A
/// diagnostic that silently stops reporting real state is worse than none,
/// because it looks like evidence.
final class DirectionDiagnosticTests: XCTestCase {

    /// L1.81 — the summary reports the settled language, not a placeholder.
    func testL1_81_summaryReportsTheSettledLanguage() {
        var l = TurnLogic()   // de↔en
        XCTAssertTrue(l.decisionSummary.contains("settled=none"),
                      "before any vote nothing is settled, and the log must say so")

        let start = Date()
        // Votes have to straddle the settle window; a settle needs both a
        // plurality and time.
        _ = l.noteInputLanguage("de", from: .de, at: start)
        _ = l.noteInputLanguage("de", from: .en, at: start)
        _ = l.noteInputLanguage("de", from: .de,
                                at: start.addingTimeInterval(TurnLogic.settleWindow + 0.1))

        XCTAssertTrue(l.decisionSummary.contains("settled=de"),
                      "a settled turn must report WHICH language settled — got: \(l.decisionSummary)")
    }

    /// L1.82 — the per-session tallies are real, and attributed to the right
    /// session. This is the field that distinguishes "both sessions agreed"
    /// from "they disagreed and one won", which on device is the difference
    /// between a model problem and an arbitration problem.
    func testL1_82_perSessionTalliesAreAttributed() {
        var l = TurnLogic()
        let t = Date()
        _ = l.noteInputLanguage("en", from: .de, at: t)   // the de session hears English
        _ = l.noteInputLanguage("de", from: .en, at: t)   // the en session hears German

        let summary = l.decisionSummary
        XCTAssertTrue(summary.contains("de[en×1]"),
                      "the de session's own tally must show what IT heard — got: \(summary)")
        XCTAssertTrue(summary.contains("en[de×1]"),
                      "and the en session's, separately — got: \(summary)")
    }

    /// L1.83 — the global vote tally is reported, so a settle that came from
    /// a plurality can be told from one that came from a single vote.
    func testL1_83_globalVotesAreReported() {
        var l = TurnLogic()
        let t = Date()
        _ = l.noteInputLanguage("de", from: .de, at: t)
        _ = l.noteInputLanguage("de", from: .en, at: t)
        _ = l.noteInputLanguage("en", from: .de, at: t)

        let summary = l.decisionSummary
        XCTAssertTrue(summary.contains("votes="), "the global tally must be present — got: \(summary)")
        XCTAssertTrue(summary.contains("de×2"), "two de votes — got: \(summary)")
        XCTAssertTrue(summary.contains("en×1"), "one en vote — got: \(summary)")
    }

    /// L1.84 — the summary is a single line. It is written into a diagnostic
    /// log that is read line by line and pasted into issues; a newline would
    /// split one turn's evidence across two entries and make the next line
    /// look like part of it. Same rule the `heard[]` line follows.
    func testL1_84_summaryIsOneLine() {
        var l = TurnLogic()
        _ = l.noteInputLanguage("de", from: .de)
        XCTAssertFalse(l.decisionSummary.contains("\n"),
                       "the summary must not break the log's one-entry-per-line contract")
    }

    /// L1.85 — the diagnostic is READ-ONLY. Building the summary must not
    /// change what the turn decides; a diagnostic that perturbs the thing it
    /// measures would be worse than none on exactly the bug it was added for.
    func testL1_85_buildingTheSummaryDecidesNothing() {
        var withSummary = TurnLogic()
        var without = TurnLogic()
        let t = Date()

        for (code, session) in [("en", TurnLogic.Lang.de), ("de", .en), ("de", .de)] {
            _ = withSummary.noteInputLanguage(code, from: session, at: t)
            _ = without.noteInputLanguage(code, from: session, at: t)
            _ = withSummary.decisionSummary   // the only difference
        }

        XCTAssertEqual(withSummary.spokenLang, without.spokenLang)
        XCTAssertEqual(withSummary.direction, without.direction)
        XCTAssertEqual(withSummary.decisionSummary, without.decisionSummary)
    }
}
