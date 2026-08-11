import XCTest
@testable import HeikoTranslate

/// GitHub #1: the session's lifecycle flags were loose `Bool`s shared
/// between the main thread (`close()`) and URLSession's delegate queue (the
/// callbacks), so an intentional close racing `didCompleteWithError` could
/// be misclassified as server-initiated — a reconnect nobody asked for — and
/// one pre-handshake failure reported `.error` from up to three sites,
/// burning the orchestrator's whole 3-attempt retry budget on one transient
/// refusal. The flags and their decisions are now one pure value
/// (`SessionLifecycle`) the class guards with a lock; these drive the value
/// through the interleavings the loose flags could lose.
final class SessionLifecycleTests: XCTestCase {

    // The misclassification race, as a state truth: once intent is recorded,
    // the completion is quiet — whatever else the transport got up to.
    func testIntentionalCloseCompletesQuietly() {
        var state = SessionLifecycle()
        state.hasOpened = true
        state.intentionalClose = true
        state.isClosing = true

        XCTAssertEqual(state.noteTaskCompleted(), .quiet,
                       "our own close must never be reported as server-initiated")
    }

    // The goAway renewal: planned close, reconnect with no cooldown.
    func testGoAwayCloseReportsPlanned() {
        var state = SessionLifecycle()
        state.hasOpened = true
        state.sawGoAway = true
        state.isClosing = true

        XCTAssertEqual(state.noteTaskCompleted(), .closed(expected: true))
    }

    // An abrupt drop after a successful handshake: unplanned, backoff path.
    func testAbruptDropReportsUnplanned() {
        var state = SessionLifecycle()
        state.hasOpened = true

        XCTAssertEqual(state.noteTaskCompleted(), .closed(expected: false))
    }

    // One pre-handshake failure, observed by the setup send, the receive
    // loop AND the task completion — in every order: exactly ONE report.
    func testPreHandshakeFailureReportsExactlyOnceInEveryOrder() {
        enum Site: CaseIterable { case send, receive, completion }
        let orders: [[Site]] = [
            [.send, .receive, .completion],
            [.send, .completion, .receive],
            [.receive, .send, .completion],
            [.receive, .completion, .send],
            [.completion, .send, .receive],
            [.completion, .receive, .send],
        ]
        for order in orders {
            var state = SessionLifecycle()
            var reports = 0
            for site in order {
                switch site {
                case .send, .receive:
                    if state.noteTransportFailure() == .reportOnce { reports += 1 }
                case .completion:
                    if state.noteTaskCompleted() == .failure { reports += 1 }
                }
            }
            XCTAssertEqual(reports, 1,
                           "order \(order): one failure must produce one report, not \(reports)")
        }
    }

    // The existing quiet paths stay quiet, and stay DISTINGUISHABLE from the
    // new suppression: noise after a close was never an error, and must not
    // start claiming the latch.
    func testFailuresAfterCloseAreIgnoredNotLatched() {
        var state = SessionLifecycle()
        state.isClosing = true

        XCTAssertEqual(state.noteTransportFailure(), .ignoredAfterClose)
        XCTAssertFalse(state.didReportFailure,
                       "expected close noise must not consume the failure report")
    }

    // Transport failures on a session that OPENED are session-end noise, not
    // connection errors — the pre-#1 behaviour, preserved.
    func testFailuresAfterOpenStayQuiet() {
        var state = SessionLifecycle()
        state.hasOpened = true

        XCTAssertEqual(state.noteTransportFailure(), .ignoredAfterClose)
    }

    // The latch is per-instance state for terminal failure only — it must
    // not swallow a later, separate genuine close report.
    func testFailureLatchDoesNotSuppressClosedReports() {
        var state = SessionLifecycle()
        XCTAssertEqual(state.noteTransportFailure(), .reportOnce)

        // The socket then somehow opens and ends (not a real sequence today,
        // but the two reports are different facts and must stay independent).
        state.hasOpened = true
        XCTAssertEqual(state.noteTaskCompleted(), .closed(expected: false))
    }
}
