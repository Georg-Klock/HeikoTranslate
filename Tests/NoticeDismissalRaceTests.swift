import XCTest
@testable import HeikoTranslate

/// GitHub #162: a dismissal already on its way must not take down a newer
/// notice.
///
/// `WallClock` queues a timer's body onto the main actor after the timer fires,
/// and invalidating the timer after that recalls nothing. The notice bodies
/// called an unqualified clear, so a notice raised in that gap — a second
/// abandoned turn landing on the first request's five-second boundary — was
/// cleared by the previous notice's dismissal, and its own timer cancelled with
/// it: the request to repeat vanished the moment it appeared. `DeferredClock`
/// reproduces the gap; every case drives a real `ConversationViewModel`.
@MainActor
final class NoticeDismissalRaceTests: XCTestCase {

    private typealias VM = ConversationViewModel

    // L1.123 — a repeat request raised while the previous one's dismissal is
    // queued survives that dismissal, and is still taken down by its own.
    func testL1_123_aQueuedDismissalLeavesANewerRepeatRequestUp() {
        let clock = DeferredClock()
        let vm = VM(clock: clock)

        vm.showUnresolvedTurnNotice()
        clock.fireArmedTimers()                 // the first request's timer fires
        vm.showUnresolvedTurnNotice()           // a second turn is abandoned in the gap
        clock.deliverQueuedBodies()             // the first dismissal runs

        XCTAssertEqual(vm.repeatRequest?.text, vm.strings.didNotCatch,
                       "the stale dismissal must not clear the newer request")

        clock.fireArmedTimers()
        XCTAssertEqual(clock.queuedCount, 1, "the newer request's own timer is still armed")
        clock.deliverQueuedBodies()
        XCTAssertNil(vm.repeatRequest, "and it comes down on its own schedule")
    }

    // L1.123b — the same for the microphone-resumed notice.
    func testL1_123b_aQueuedDismissalLeavesANewerMicNoticeUp() {
        let clock = DeferredClock()
        let vm = VM(clock: clock)

        vm.showMicNotice()
        clock.fireArmedTimers()
        vm.showMicNotice()
        clock.deliverQueuedBodies()

        XCTAssertEqual(vm.micNotice?.text, vm.strings.micResumed,
                       "the stale dismissal must not clear the newer notice")

        clock.fireArmedTimers()
        XCTAssertEqual(clock.queuedCount, 1, "the newer notice's own timer is still armed")
        clock.deliverQueuedBodies()
        XCTAssertNil(vm.micNotice)
    }

    // L1.123c — a dismissal queued before an explicit clear stays harmless
    // when it lands after a new notice. Clearing is the other way a notice ends
    // (a tap, a stop), and it has the same gap.
    func testL1_123c_aDismissalQueuedBeforeAClearDoesNotReachTheNextNotice() {
        let clock = DeferredClock()
        let vm = VM(clock: clock)

        vm.showUnresolvedTurnNotice()
        vm.showMicNotice()
        clock.fireArmedTimers()
        vm.clearRepeatRequest()
        vm.clearMicNotice()
        vm.showUnresolvedTurnNotice()
        vm.showMicNotice()
        clock.deliverQueuedBodies()

        XCTAssertEqual(vm.repeatRequest?.text, vm.strings.didNotCatch)
        XCTAssertEqual(vm.micNotice?.text, vm.strings.micResumed)
    }

    // L1.123d — the double has the gap the shipping clock has: a body queued
    // before `invalidate()` still runs, and a timer invalidated before it fires
    // queues nothing. Without the first half the cases above would pass on a
    // clock that cannot reproduce the defect.
    func testL1_123d_theDeferredClockKeepsTheShippingClocksHop() {
        let clock = DeferredClock()
        var ran = 0

        let queuedFirst = clock.schedule(after: 5) { ran += 1 }
        clock.fireArmedTimers()
        queuedFirst.invalidate()
        clock.deliverQueuedBodies()
        XCTAssertEqual(ran, 1, "invalidating after the fire recalls nothing")

        let cancelled = clock.schedule(after: 5) { ran += 1 }
        cancelled.invalidate()
        clock.fireArmedTimers()
        XCTAssertEqual(clock.queuedCount, 0)
        clock.deliverQueuedBodies()
        XCTAssertEqual(ran, 1, "invalidating before the fire is the ordinary fast path")
    }
}
