import AVFAudio
import SwiftUI
import XCTest
@testable import HeikoTranslate

/// GitHub #13: every start trigger used to spawn its own unstructured task,
/// so two taps during a slow permission prompt ran the gate concurrently and
/// both called the service start — and a prompt still up while the app
/// backgrounded could return granted and open the microphone off screen.
///
/// These drive the REAL paths — `toggleButton()`, `beginListening()`,
/// `handleScenePhase()` — with the permission prompt replaced by a
/// continuation the test resolves by hand, so the interleavings that were
/// device-only races become deterministic cases. The seam stands in only for
/// the prompt and the audio/network step; every decision in between is the
/// shipping code.
@MainActor
final class PendingStartTests: XCTestCase {

    /// A permission prompt the test answers when it chooses.
    private final class HeldPrompt {
        var pending: [CheckedContinuation<Bool, Never>] = []
        func request() async -> Bool {
            await withCheckedContinuation { pending.append($0) }
        }
        func resolve(_ granted: Bool) {
            guard !pending.isEmpty else { return }
            pending.removeFirst().resume(returning: granted)
        }
    }

    private func makeModel(prompt: HeldPrompt) -> ConversationViewModel {
        let vm = ConversationViewModel()
        vm.permissionRequestForTesting = { await prompt.request() }
        vm.serviceStartForTesting = { true }
        return vm
    }

    /// Let spawned main-actor tasks run up to their next suspension.
    private func drain() async {
        for _ in 0..<25 { await Task.yield() }
    }

    /// The real notification `handleAudioInterruption` parses, so tests can
    /// drive the production interruption path end to end — including the
    /// resume task `.ended` schedules, which the seam methods alone never
    /// reach.
    private static func interruption(_ type: AVAudioSession.InterruptionType) -> Notification {
        Notification(name: AVAudioSession.interruptionNotification, object: nil,
                     userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue])
    }

    // Two taps during a delayed permission response: exactly ONE service
    // start. Before the fix both taps awaited the prompt and both started.
    func testTwoTapsOneStart() async {
        let prompt = HeldPrompt()
        let vm = makeModel(prompt: prompt)

        vm.toggleButton()
        await drain()
        XCTAssertTrue(vm.isLaunching, "the first tap owns a pending start")

        vm.toggleButton()          // the accidental double-tap
        await drain()
        XCTAssertEqual(prompt.pending.count, 1,
                       "the second tap must not have queued its own prompt")

        // Answer every prompt anyone queued: correct code queued exactly one,
        // and the second answer is what would let a racing duplicate proceed
        // rather than hang — a regression must FAIL this suite, not stall it.
        prompt.resolve(true)
        await drain()
        prompt.resolve(true)
        await drain()

        XCTAssertEqual(vm.serviceStartCount, 1,
                       "two taps during one prompt must produce exactly one start")
        XCTAssertTrue(vm.isListening, "and the double-tap must still end up listening")
    }

    // A second trigger arriving as a direct beginListening() call (an
    // automatic resume racing a tap) is refused the same way.
    func testConcurrentBeginListeningIsRefused() async {
        let prompt = HeldPrompt()
        let vm = makeModel(prompt: prompt)

        vm.toggleButton()
        await drain()

        async let second: Void = vm.beginListening()
        await drain()
        // Two answers for at most two prompts, so a regression that lets the
        // second call queue its own prompt fails on the count instead of
        // deadlocking `await second`.
        prompt.resolve(true)
        await drain()
        prompt.resolve(true)
        await second

        XCTAssertEqual(vm.serviceStartCount, 1)
        XCTAssertTrue(vm.isListening)
    }

    // Backgrounding while the prompt is up: the grant that arrives afterwards
    // must not start audio or sockets. Zero starts, and the spinner state is
    // cleared — returning active requires a fresh tap.
    func testBackgroundingInvalidatesThePendingStart() async {
        let prompt = HeldPrompt()
        let vm = makeModel(prompt: prompt)

        vm.toggleButton()
        await drain()
        XCTAssertTrue(vm.isLaunching)

        vm.handleScenePhase(.background)
        XCTAssertFalse(vm.isLaunching, "backgrounding voids the pending start")

        prompt.resolve(true)   // the stale grant
        await drain()

        XCTAssertEqual(vm.serviceStartCount, 0,
                       "a grant returning to a backgrounded app must start nothing")
        XCTAssertFalse(vm.isListening)
        XCTAssertFalse(vm.resumeWhenActive,
                       "a start that never happened earns no automatic resume")

        // A fresh tap afterwards works normally.
        vm.toggleButton()
        await drain()
        prompt.resolve(true)
        await drain()
        XCTAssertEqual(vm.serviceStartCount, 1)
        XCTAssertTrue(vm.isListening)
    }

    // The ownership subtlety the first draft of the fix got wrong: a stale
    // grant resolving AFTER a newer start is already pending must not clear
    // the newer start's spinner or start anything itself.
    func testStaleGrantDoesNotTouchANewerPendingStart() async {
        let prompt = HeldPrompt()
        let vm = makeModel(prompt: prompt)

        vm.toggleButton()                      // start #1
        await drain()
        vm.handleScenePhase(.background)       // voids it, prompt still up
        vm.toggleButton()                      // start #2, its own prompt
        await drain()
        XCTAssertTrue(vm.isLaunching)
        XCTAssertEqual(prompt.pending.count, 2)

        prompt.resolve(true)                   // the STALE grant (#1's)
        await drain()
        XCTAssertTrue(vm.isLaunching,
                      "the stale grant must not clear the newer start's in-flight state")
        XCTAssertEqual(vm.serviceStartCount, 0)

        prompt.resolve(true)                   // the current grant (#2's)
        await drain()
        XCTAssertEqual(vm.serviceStartCount, 1)
        XCTAssertTrue(vm.isListening)
    }

    // A denial still clears the launch state and raises the Settings
    // guidance — the gate must not have changed the denied path.
    func testDenialStillExplainsSettings() async {
        let prompt = HeldPrompt()
        let vm = makeModel(prompt: prompt)

        vm.toggleButton()
        await drain()
        prompt.resolve(false)
        await drain()

        XCTAssertFalse(vm.isLaunching)
        XCTAssertTrue(vm.micPermissionDenied)
        XCTAssertEqual(vm.errorMessage, vm.strings.micDenied)
        XCTAssertEqual(vm.serviceStartCount, 0)
    }

    // An audio interruption (call, Siri, alarm) beginning while the prompt
    // is still up voids the pending start. The regression this pins: the
    // listening guard in noteInterruptionBegan() returned early in exactly
    // the pending state (isListening still false), so the grant arriving
    // mid-interruption started the microphone and sockets while iOS owned
    // the audio. This drives the REAL noteInterruptionBegan() with the app
    // genuinely not listening — no hand-forced flags.
    func testInterruptionBeganVoidsThePendingStart() async {
        let prompt = HeldPrompt()
        let vm = makeModel(prompt: prompt)

        vm.toggleButton()
        await drain()
        XCTAssertTrue(vm.isLaunching, "the tap owns a pending start")

        XCTAssertFalse(vm.noteInterruptionBegan(),
                       "nothing was listening, so there is nothing to tear down")
        XCTAssertFalse(vm.isLaunching, "interruption-began voids the pending start")
        XCTAssertFalse(vm.resumeWhenActive,
                       "a start that never happened earns no automatic resume")

        prompt.resolve(true)       // the grant arrives mid-interruption
        await drain()

        XCTAssertEqual(vm.serviceStartCount, 0,
                       "a grant during an interruption must start nothing")
        XCTAssertFalse(vm.isListening)

        // The interruption ending must not start anything either — no
        // resume was armed for a session that never ran.
        XCTAssertFalse(vm.noteInterruptionEnded(options: 0))
        await drain()
        XCTAssertEqual(vm.serviceStartCount, 0)

        // A fresh tap afterwards works normally.
        vm.toggleButton()
        await drain()
        prompt.resolve(true)
        await drain()
        XCTAssertEqual(vm.serviceStartCount, 1)
        XCTAssertTrue(vm.isListening)
    }

    // The pre-scheduling race: cancellation is cooperative, so a task
    // cancelled before its first actor turn still enters its body. Before
    // the scheduling stamp, a tap immediately followed by backgrounding
    // produced exactly that task — it set the launch state, minted a fresh
    // generation (which made the stale-grant guard pass), and requested
    // permission; its early return then left the UI launching forever, so
    // every future tap hit the deliberate no-op branch.
    func testBackgroundingBeforeTheQueuedStartRunsStartsNothing() async {
        let prompt = HeldPrompt()
        let vm = makeModel(prompt: prompt)

        vm.toggleButton()                 // schedules the start …
        vm.handleScenePhase(.background)  // … voided before its first actor turn
        await drain()

        XCTAssertTrue(prompt.pending.isEmpty,
                      "a superseded start must not even request permission")
        XCTAssertEqual(vm.serviceStartCount, 0)
        XCTAssertFalse(vm.isLaunching,
                       "no launch state may be left behind by a start that never was")
        XCTAssertFalse(vm.isListening)
        XCTAssertFalse(vm.resumeWhenActive)

        // The UI is not wedged: a fresh tap works.
        vm.toggleButton()
        await drain()
        prompt.resolve(true)
        await drain()
        XCTAssertEqual(vm.serviceStartCount, 1)
        XCTAssertTrue(vm.isListening)
    }

    // The interruption-ended resume used to be a loose `Task` nothing owned:
    // backgrounding before it ran could not void it, and it started audio
    // later with the app off screen. Through the owned path, a background
    // arriving first kills it before it requests anything.
    func testBackgroundingVoidsAScheduledResume() async {
        let prompt = HeldPrompt()
        let vm = makeModel(prompt: prompt)

        vm.simulateInterruptionBeganForTesting()          // arms the resume
        XCTAssertTrue(vm.resumeWhenActive)

        vm.handleAudioInterruption(Self.interruption(.ended))  // schedules it
        XCTAssertFalse(vm.resumeWhenActive, "the scheduled task claims the resume")
        vm.handleScenePhase(.background)                  // …voids it before it runs
        await drain()

        XCTAssertTrue(prompt.pending.isEmpty,
                      "a voided resume must not even request permission")
        XCTAssertEqual(vm.serviceStartCount, 0)
        XCTAssertFalse(vm.isLaunching)
        XCTAssertFalse(vm.isListening)
        XCTAssertFalse(vm.resumeWhenActive, "no stale resume is left armed")

        // A fresh tap afterwards works normally.
        vm.toggleButton()
        await drain()
        prompt.resolve(true)
        await drain()
        XCTAssertEqual(vm.serviceStartCount, 1)
        XCTAssertTrue(vm.isListening)
    }

    // Same shape, other trigger: the phone rings again before the scheduled
    // resume gets its first actor turn. The new interruption-began voids it.
    func testANewInterruptionVoidsAScheduledResume() async {
        let prompt = HeldPrompt()
        let vm = makeModel(prompt: prompt)

        vm.simulateInterruptionBeganForTesting()
        vm.handleAudioInterruption(Self.interruption(.ended))
        vm.handleAudioInterruption(Self.interruption(.began))  // rings again
        await drain()

        XCTAssertTrue(prompt.pending.isEmpty)
        XCTAssertEqual(vm.serviceStartCount, 0)
        XCTAssertFalse(vm.isLaunching)
        XCTAssertFalse(vm.isListening)
        XCTAssertFalse(vm.resumeWhenActive)
    }

    // The positive half, so the two cases above cannot pass by the resume
    // path having been dropped entirely: an undisturbed interruption-ended
    // resume still starts, exactly once.
    func testAnUndisturbedResumeStillStarts() async {
        let prompt = HeldPrompt()
        let vm = makeModel(prompt: prompt)

        vm.simulateInterruptionBeganForTesting()
        vm.handleAudioInterruption(Self.interruption(.ended))
        await drain()
        prompt.resolve(true)
        await drain()

        XCTAssertEqual(vm.serviceStartCount, 1)
        XCTAssertTrue(vm.isListening)
        XCTAssertEqual(vm.automaticResumeCount, 1)
    }

    // A manual mute while a start is somehow pending (mute reached through a
    // path other than the button) voids the start: a stale grant must not
    // restart what was just stopped.
    func testStopVoidsThePendingStart() async {
        let prompt = HeldPrompt()
        let vm = makeModel(prompt: prompt)

        vm.toggleButton()
        await drain()

        vm.forceListeningForTesting()
        vm.toggleButton()          // the stop branch
        await drain()

        prompt.resolve(true)       // the stale grant
        await drain()

        XCTAssertEqual(vm.serviceStartCount, 0,
                       "a grant from before the stop must not restart the session")
        XCTAssertFalse(vm.isListening)
    }
}
