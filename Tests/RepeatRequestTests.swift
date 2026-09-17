import XCTest
@testable import HeikoTranslate

/// GitHub #161: the request to repeat a discarded turn has to reach the screen.
///
/// "Nicht verstanden — bitte wiederholen." rode the microphone-resumed notice's
/// slot, and every standing warning outranks that notice. A turn is abandoned
/// most often exactly while the connection is degraded or silent, so the one
/// instruction that tells the speaker to act was hidden in the case it exists
/// for — and its five seconds ran out behind the warning, leaving nothing to
/// show once the connection recovered. SPEC §5.1, R8.
///
/// Every case drives a real `ConversationViewModel` on a `ManualClock` and
/// reads `slotNotice`, the value the view draws.
@MainActor
final class RepeatRequestTests: XCTestCase {

    private typealias VM = ConversationViewModel

    // L1.122 — a turn abandoned under each connection warning is announced.
    func testL1_122_theRepeatRequestShowsOverEveryConnectionWarning() {
        for quality: GeminiLiveTranslationService.ConnectionQuality in [.degraded, .silent, .offline] {
            let vm = VM(clock: ManualClock())
            vm.forceListeningForTesting()
            vm.handleConnectionQuality(quality)
            XCTAssertNotNil(vm.connectionWarning, "precondition: a warning stands for \(quality)")

            vm.showUnresolvedTurnNotice()

            XCTAssertEqual(vm.slotNotice?.text, vm.strings.didNotCatch,
                           "the discarded turn must be announced over the \(quality) warning")
        }
    }

    // L1.122b — and under the echo warning (#130), alone or with a connection
    // warning on top of it.
    func testL1_122b_theRepeatRequestShowsOverTheEchoWarning() {
        let vm = VM(clock: ManualClock())
        vm.forceListeningForTesting()
        vm.handleEchoCancellation(active: false)
        XCTAssertNotNil(vm.echoWarning, "precondition: the echo warning stands")

        vm.showUnresolvedTurnNotice()
        XCTAssertEqual(vm.slotNotice?.text, vm.strings.didNotCatch)

        vm.handleConnectionQuality(.silent)
        XCTAssertEqual(vm.slotNotice?.text, vm.strings.didNotCatch,
                       "a warning arriving after the request does not cover it")
    }

    // L1.122c — its lifetime is time on screen. It stays up for the whole
    // reviewed duration while a warning stands, a warning arriving part-way
    // does not cut it short, and the warning shows through afterwards.
    func testL1_122c_theRequestIsVisibleForItsWholeDurationThenTheWarningReturns() {
        let clock = ManualClock()
        let vm = VM(clock: clock)
        vm.forceListeningForTesting()
        vm.handleEchoCancellation(active: false)

        vm.showUnresolvedTurnNotice()
        clock.advance(by: 2)
        vm.handleConnectionQuality(.silent)
        XCTAssertEqual(vm.slotNotice?.text, vm.strings.didNotCatch)

        clock.advance(by: VM.micNoticeDuration - 2 - 0.05)
        XCTAssertEqual(vm.slotNotice?.text, vm.strings.didNotCatch,
                       "visible for the whole duration, not expiring behind a warning")

        clock.advance(by: 0.1)
        XCTAssertEqual(vm.slotNotice, vm.connectionWarning,
                       "once it has been read, the standing warning shows through again")
        XCTAssertEqual(vm.slotNotice?.text, vm.strings.noServerResponse)
    }

    // L1.122d — what did not change: the microphone-resumed notice still yields
    // to a standing warning (L1.41f), and stopping takes a request to repeat
    // down with it — asking someone to speak into a microphone that is off
    // asks for something that cannot work (L1.76c).
    func testL1_122d_theResumeNoticeStillYieldsAndStoppingClearsTheRequest() {
        let clock = ManualClock()
        let resumed = VM(clock: clock)
        resumed.forceListeningForTesting()
        resumed.handleConnectionQuality(.degraded)
        resumed.showMicNotice()
        XCTAssertEqual(resumed.slotNotice, resumed.connectionWarning,
                       "the informational notice is still the lowest occupant")

        let stopped = VM(clock: clock)
        stopped.forceListeningForTesting()
        stopped.showUnresolvedTurnNotice()
        stopped.toggleButton()                 // the stop branch; needs no session
        XCTAssertFalse(stopped.isListening)
        XCTAssertNil(stopped.slotNotice, "the request does not outlive the listening it asked for")
        clock.advance(by: VM.micNoticeDuration * 2)
        XCTAssertNil(stopped.slotNotice)
        XCTAssertEqual(clock.armedCount, 0, "and nothing is left armed")
    }

    // L1.122e — the whole order, one occupant against each below it.
    func testL1_122e_theSlotsFullPrecedence() {
        let repeatRequest = VM.StatusNotice(text: "repeat", severity: .info)
        let connection = VM.StatusNotice(text: "connection", severity: .lost)
        let echo = VM.StatusNotice(text: "echo", severity: .degraded)
        let resumed = VM.StatusNotice(text: "resumed", severity: .info)

        XCTAssertNil(VM.bottomNotice(muted: true, repeatRequest: repeatRequest, warning: connection,
                                     echoWarning: echo, micNotice: resumed),
                     "muted outranks everything, the request to repeat included")
        XCTAssertEqual(VM.bottomNotice(muted: false, repeatRequest: repeatRequest, warning: connection,
                                       echoWarning: echo, micNotice: resumed), repeatRequest)
        XCTAssertEqual(VM.bottomNotice(muted: false, repeatRequest: repeatRequest, warning: nil,
                                       echoWarning: echo, micNotice: resumed), repeatRequest)
        XCTAssertEqual(VM.bottomNotice(muted: false, repeatRequest: repeatRequest, warning: nil,
                                       echoWarning: nil, micNotice: resumed), repeatRequest)
        XCTAssertEqual(VM.bottomNotice(muted: false, repeatRequest: nil, warning: connection,
                                       echoWarning: echo, micNotice: resumed), connection)
        XCTAssertEqual(VM.bottomNotice(muted: false, repeatRequest: nil, warning: nil,
                                       echoWarning: echo, micNotice: resumed), echo)
        XCTAssertEqual(VM.bottomNotice(muted: false, repeatRequest: nil, warning: nil,
                                       echoWarning: nil, micNotice: resumed), resumed)
        XCTAssertNil(VM.bottomNotice(muted: false, repeatRequest: nil, warning: nil,
                                     echoWarning: nil, micNotice: nil))
    }
}
