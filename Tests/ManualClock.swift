import Foundation
@testable import HeikoTranslate

/// A clock a test owns. GitHub #153.
///
/// Timers arm against a virtual `now` and fire only when the test advances
/// it, in fire order, synchronously on the main actor — so a chain the app
/// builds (transcript idle → speaker stopped → finalize → output tail) runs
/// exactly as the shipping timers would run it, without the test racing the
/// wall clock. A body that arms a further timer inside the advanced window
/// fires within the same `advance`, the way a real timer scheduled from a
/// firing timer would.
@MainActor
final class ManualClock: TimerScheduling {
    private(set) var now: Date

    private final class Entry: ScheduledTimer {
        var fireAt: Date
        let interval: TimeInterval
        let repeats: Bool
        let body: @MainActor () -> Void
        let serial: Int
        var isValid = true

        init(fireAt: Date, interval: TimeInterval, repeats: Bool, serial: Int,
             body: @escaping @MainActor () -> Void) {
            self.fireAt = fireAt
            self.interval = interval
            self.repeats = repeats
            self.serial = serial
            self.body = body
        }

        func invalidate() { isValid = false }
    }

    private var pending: [Entry] = []
    private var nextSerial = 0

    /// Starts on a fixed, arbitrary instant rather than `Date()`, so a test
    /// that compares timestamps cannot accidentally depend on the wall clock.
    nonisolated init(start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
        now = start
    }

    /// Timers armed and not yet fired or invalidated.
    var armedCount: Int { pending.filter(\.isValid).count }

    @discardableResult
    func schedule(after interval: TimeInterval, repeats: Bool,
                  _ body: @escaping @MainActor () -> Void) -> any ScheduledTimer {
        nextSerial += 1
        // Foundation clamps a timer's interval to 0.1ms; a repeating timer at
        // zero would otherwise never advance and `advance(by:)` would spin.
        let interval = max(interval, 0.0001)
        let entry = Entry(fireAt: now.addingTimeInterval(interval), interval: interval,
                          repeats: repeats, serial: nextSerial, body: body)
        pending.append(entry)
        return entry
    }

    /// Move time forward, firing every timer due inside the window in the
    /// order it is due (ties in arming order), with `now` at each timer's
    /// own fire instant while its body runs. Due means `fireAt <= target`
    /// on `Date`'s double, so a test that wants to land exactly on a
    /// boundary should overshoot it by a little rather than trust the sum.
    func advance(by interval: TimeInterval) {
        let target = now.addingTimeInterval(interval)
        while true {
            pending.removeAll { !$0.isValid }
            guard let next = pending
                .filter({ $0.fireAt <= target })
                .min(by: { ($0.fireAt, $0.serial) < ($1.fireAt, $1.serial) })
            else { break }
            now = max(now, next.fireAt)
            if next.repeats {
                next.fireAt = next.fireAt.addingTimeInterval(next.interval)
            } else {
                next.isValid = false
            }
            next.body()
        }
        now = target
    }
}
