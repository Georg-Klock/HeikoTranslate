import XCTest
@testable import HeikoTranslate

/// GitHub #153: the L1 suite used to wait on the wall clock for the
/// service's real timers, and under machine load it lost the race — `main`
/// went red twice on a byte-identical tree, with a failure that said "a
/// turn did not commit". The service now reads time and arms timers through
/// `TimerScheduling` only. These tests pin the seam itself: that the app's
/// two timer-owning types have no way around it, that the test double
/// fires the way real timers fire, and that the shipping clock does fire.
@MainActor
final class ClockSeamTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/ClockSeamTests.swift
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // repo root
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The file with every `#if DEBUG … #endif` region removed — what ships.
    /// The view model's DEBUG demo replay films a scripted conversation on
    /// `Task.sleep`; it never runs under test and is not what the scan is
    /// for. Everything outside those regions is.
    private func shippingSource(_ text: String) -> String {
        var depth = 0
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if DEBUG") { depth += 1; continue }
            if depth > 0 {
                if trimmed.hasPrefix("#if") { depth += 1 }
                if trimmed.hasPrefix("#endif") { depth -= 1 }
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// L1.95 — no timer and no clock read outside the seam. A `Timer` armed
    /// directly is one a test can only wait for; a bare `Date()` beside a
    /// virtual clock compares two different times. The scan is what keeps
    /// the next timer from going back to the old way.
    func testL1_95_theServiceAndViewModelOwnNoTimerOutsideTheSeam() throws {
        let service = try source("HeikoTranslate/Services/GeminiLiveTranslationService.swift")
        for forbidden in ["Timer.scheduledTimer(", "Task.sleep(", "Date()", "asyncAfter("] {
            XCTAssertFalse(service.contains(forbidden),
                           "the service must reach time through `clock` — found `\(forbidden)`")
        }
        // The view model's shipping code — its DEBUG demo replay excluded —
        // is held to the same rule, `Task.sleep` included: the 0.4s settle
        // debounce L1.45 exists to keep out was a `Task.sleep` here, and a
        // scan that exempted the whole file would wave it back in.
        let viewModel = shippingSource(try source("HeikoTranslate/ConversationViewModel.swift"))
        XCTAssertTrue(viewModel.contains("func languageSelectionDidFinish()"),
                      "sanity: the DEBUG stripper kept the shipping code")
        for forbidden in ["Timer.scheduledTimer(", "Task.sleep(", "Date()", "asyncAfter("] {
            XCTAssertFalse(viewModel.contains(forbidden),
                           "the view model must reach time through `clock` — found `\(forbidden)`")
        }
    }

    /// L1.96 — the manual clock fires in due order, holds `now` at each
    /// timer's own instant while it runs, and lets a body arm a follow-up
    /// that fires inside the same advance. This is the shape of every timer
    /// chain in the service, so the double has to get it right or the
    /// converted tests prove nothing.
    func testL1_96_manualClockFiresInDueOrderAndChainsWithinOneAdvance() {
        let clock = ManualClock()
        let start = clock.now
        var log: [String] = []

        clock.schedule(after: 2.0) { log.append("b@\(clock.now.timeIntervalSince(start))") }
        clock.schedule(after: 1.0) {
            log.append("a@\(clock.now.timeIntervalSince(start))")
            clock.schedule(after: 0.5) { log.append("a2@\(clock.now.timeIntervalSince(start))") }
        }
        clock.schedule(after: 5.0) { log.append("late") }

        clock.advance(by: 3.0)
        XCTAssertEqual(log, ["a@1.0", "a2@1.5", "b@2.0"],
                       "due order, not arming order; the chained timer fires at its own instant")
        XCTAssertEqual(clock.now.timeIntervalSince(start), 3.0, "the clock ends on the target")
        XCTAssertEqual(clock.armedCount, 1, "only the 5s timer is still armed")
    }

    /// L1.96b — invalidation and repetition behave as `Timer` does: an
    /// invalidated one-shot never fires, a repeating timer fires every
    /// interval until invalidated, and invalidating from inside its own
    /// body stops it.
    func testL1_96b_manualClockHonoursInvalidationAndRepeats() {
        let clock = ManualClock()
        var oneShot = 0
        var ticks = 0

        let cancelled = clock.schedule(after: 1.0) { oneShot += 1 }
        cancelled.invalidate()
        var repeating: (any ScheduledTimer)?
        repeating = clock.schedule(after: 0.25, repeats: true) {
            ticks += 1
            if ticks == 3 { repeating?.invalidate() }
        }

        clock.advance(by: 2.0)
        XCTAssertEqual(oneShot, 0, "an invalidated timer never fires")
        XCTAssertEqual(ticks, 3, "a repeating timer fires each interval until its body invalidates it")
        XCTAssertEqual(clock.armedCount, 0)
    }

    /// L1.97 — the shipping clock arms a real timer that fires on the main
    /// actor. This one test waits on the wall clock on purpose: a 50ms
    /// timer against a 10s allowance, which fails only if the machine is
    /// unresponsive for ten seconds — nothing like the sub-second margins
    /// #153 removed. Without it, the seam could be wired to a `WallClock`
    /// whose timers never fire and every other test would still pass.
    func testL1_97_wallClockFiresOnTheMainActor() {
        let clock = WallClock()
        let fired = expectation(description: "the timer fires")
        clock.schedule(after: 0.05) { fired.fulfill() }
        wait(for: [fired], timeout: 10)
        XCTAssertLessThan(abs(clock.now.timeIntervalSinceNow), 1, "`now` is the wall clock")
    }

    /// L1.98 — the view model's mic notice dismisses on the clock. Converted
    /// from `Task.sleep`; the duration is the reviewed one and a test can
    /// now assert it instead of trusting it.
    func testL1_98_micNoticeDismissesOnTheClock() {
        let clock = ManualClock()
        let vm = ConversationViewModel(clock: clock)

        vm.showMicNotice()
        XCTAssertNotNil(vm.micNotice)
        clock.advance(by: ConversationViewModel.micNoticeDuration - 0.05)
        XCTAssertNotNil(vm.micNotice, "the notice stays up for its whole duration")
        clock.advance(by: 0.1)
        XCTAssertNil(vm.micNotice, "and comes down on the clock, without anyone sleeping for it")

        vm.showMicNotice()
        vm.clearMicNotice()
        clock.advance(by: ConversationViewModel.micNoticeDuration * 2)
        XCTAssertNil(vm.micNotice, "clearing cancels the dismissal — no stale timer clears a later notice")
        XCTAssertEqual(clock.armedCount, 0)
    }
}
