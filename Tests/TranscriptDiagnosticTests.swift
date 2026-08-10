import XCTest
@testable import HeikoTranslate

/// L1 coverage for the diagnostic line emitted by the real live service at a
/// successful turn commit. The line is evidence only: it must retain both
/// sessions' raw inputs rather than quietly reproducing TurnLogic's winner.
@MainActor
final class TranscriptDiagnosticTests: XCTestCase {

    /// L1.63 — the sessions disagree on a number. The log must make both
    /// answers visible in a deterministic order so a remote reviewer can tell
    /// selection failure from a shared transcription failure.
    func testL1_63_commitSnapshotRetainsBothDisagreeingSessions() {
        let line = GeminiLiveTranslationService.inputTranscriptDiagnosticLine(
            inputs: [.de: "312. 12.", .en: "313. 12."],
            sessions: [.en, .de]
        )

        XCTAssertEqual(line, "  heard[de] \"312. 12.\"   heard[en] \"313. 12.\"")
    }

    /// L1.63b — active sessions must be logged even if one produced no text,
    /// and one transcript must not be able to break the append-only log into
    /// counterfeit lines. A non-active session's stale input is excluded.
    func testL1_63b_commitSnapshotEscapesAndLogsEveryActiveSession() {
        let line = GeminiLiveTranslationService.inputTranscriptDiagnosticLine(
            inputs: [.de: "stale", .en: "say \"hello\"\nagain"],
            sessions: [.es, .en]
        )

        XCTAssertEqual(line, "  heard[en] \"say \\\"hello\\\"\\nagain\"   heard[es] \"\"")
        XCTAssertFalse(line.contains("heard[de]"))
    }
}
