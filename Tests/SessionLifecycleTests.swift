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

    // The gap the review caught: intent recorded, transport not yet marked
    // closing — the interval close() used to leave between two separate lock
    // acquisitions. Intent alone is an expected close; a failure landing
    // there is teardown noise, not a reportable error, and must not claim
    // the latch for a stop the user asked for.
    func testIntentAloneIsAnExpectedClose() {
        var state = SessionLifecycle()
        state.intentionalClose = true   // isClosing deliberately NOT set

        XCTAssertEqual(state.noteTransportFailure(), .ignoredAfterClose,
                       "a user-requested close is expected from the moment it is intended")
        XCTAssertFalse(state.didReportFailure,
                       "teardown noise must not consume the failure report")
        XCTAssertEqual(state.noteTaskCompleted(), .quiet)
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
    // Phone-day case 8 (GitHub #9): a dead key COMPLETES the handshake and
    // is then closed 1008 with an auth-rejection reason — which, without
    // the reason check, was an "abrupt drop" and reconnected forever. The
    // observed reason text is reproduced verbatim from the device log.
    func testAuthRejectedCloseIsNotADrop() {
        var state = SessionLifecycle()
        state.hasOpened = true
        state.isClosing = true
        state.closeReason = "Request had invalid authentication credentials. "
            + "Expected OAuth 2 access token, login cookie or other valid authentication c"
        XCTAssertEqual(state.noteTaskCompleted(),
                       .authRejected(state.closeReason!),
                       "capped retries + key probe, never reconnect-forever")
    }

    func testOrdinaryCloseReasonStaysADrop() {
        var state = SessionLifecycle()
        state.hasOpened = true
        state.isClosing = true
        state.closeReason = "(no reason given)"
        XCTAssertEqual(state.noteTaskCompleted(), .closed(expected: false))
    }

    func testGoAwayOutranksAStaleAuthReason() {
        // A planned end is a planned end: the 1008 that can follow a slow
        // goAway close (GitHub #65's tail) must not convict anything.
        var state = SessionLifecycle()
        state.hasOpened = true
        state.sawGoAway = true
        state.closeReason = "Request had invalid authentication credentials."
        XCTAssertEqual(state.noteTaskCompleted(), .closed(expected: true))
    }

    func testIntentionalCloseOutranksAuthReason() {
        var state = SessionLifecycle()
        state.hasOpened = true
        state.intentionalClose = true
        state.closeReason = "Request had invalid authentication credentials."
        XCTAssertEqual(state.noteTaskCompleted(), .quiet)
    }

}
