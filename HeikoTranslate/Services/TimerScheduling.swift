import Foundation

/// A timer as the service holds one: the only thing it may do with it is
/// invalidate it.
@MainActor
protocol ScheduledTimer: AnyObject {
    func invalidate()
}

/// The one door through which the service reads the clock and arms timers.
///
/// Every `Date()` and every `Timer.scheduledTimer` the service used to call
/// goes through here instead. The decision rules were already pure and took
/// `now:` — `TurnCoordinator.finalization(for:at:)`, `SpeechEndPolicy`,
/// `FinalizePolicy` — but the service armed platform timers around them,
/// and a test could only wait for those with `Task.sleep`. Under machine
/// load the sleep lost the race against the real timers, and the failure
/// said "a turn did not commit", which is also what a genuine break says
/// (GitHub #153: `main` went red twice on a byte-identical tree). A test now
/// injects `ManualClock`, drives the same timers the app arms, and advances
/// a virtual clock past them.
///
/// The body runs on the main actor when the timer fires — for a repeating
/// timer, every `interval` until it is invalidated.
@MainActor
protocol TimerScheduling: AnyObject {
    var now: Date { get }
    @discardableResult
    func schedule(after interval: TimeInterval, repeats: Bool,
                  _ body: @escaping @MainActor () -> Void) -> any ScheduledTimer
}

extension TimerScheduling {
    /// A one-shot timer — the common case.
    @discardableResult
    func schedule(after interval: TimeInterval,
                  _ body: @escaping @MainActor () -> Void) -> any ScheduledTimer {
        schedule(after: interval, repeats: false, body)
    }
}

/// The shipping clock: `Date()` and `Timer.scheduledTimer`, exactly as the
/// service called them before the seam existed. The hop onto the main actor
/// is the one every timer block already made.
@MainActor
final class WallClock: TimerScheduling {
    /// Nonisolated so it can stand as a default argument — those are
    /// evaluated outside any actor.
    nonisolated init() {}

    var now: Date { Date() }

    @discardableResult
    func schedule(after interval: TimeInterval, repeats: Bool,
                  _ body: @escaping @MainActor () -> Void) -> any ScheduledTimer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            Task { @MainActor in body() }
        }
        return WallTimer(timer)
    }

    private final class WallTimer: ScheduledTimer {
        private let timer: Timer
        init(_ timer: Timer) { self.timer = timer }
        func invalidate() { timer.invalidate() }
    }
}
