import Foundation
@testable import HeikoTranslate

/// A clock that keeps the shipping clock's extra hop. GitHub #162.
///
/// `WallClock` does not run a timer's body when the Foundation timer fires: the
/// timer's callback queues the body in a `Task { @MainActor in … }`, and the
/// body runs whenever the main actor gets to it. Between the two, `invalidate()`
/// has nothing left to recall — the timer is spent and the task is already
/// queued. `ManualClock` delivers inline, so that window does not exist under
/// it. This double splits the two steps so a test can put work into the gap:
/// `fireArmedTimers()` is the Foundation timer firing, `deliverQueuedBodies()`
/// is the main actor running what was queued.
@MainActor
final class DeferredClock: TimerScheduling {
    private(set) var now: Date

    private final class Entry: ScheduledTimer {
        let repeats: Bool
        let body: @MainActor () -> Void
        var isValid = true

        init(repeats: Bool, body: @escaping @MainActor () -> Void) {
            self.repeats = repeats
            self.body = body
        }

        func invalidate() { isValid = false }
    }

    private var armed: [Entry] = []
    private var queued: [@MainActor () -> Void] = []

    nonisolated init(start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) {
        now = start
    }

    /// Bodies handed to the main actor and not yet run.
    var queuedCount: Int { queued.count }

    @discardableResult
    func schedule(after interval: TimeInterval, repeats: Bool,
                  _ body: @escaping @MainActor () -> Void) -> any ScheduledTimer {
        let entry = Entry(repeats: repeats, body: body)
        armed.append(entry)
        return entry
    }

    /// Every armed timer that is still valid fires: its body is queued, as
    /// `WallClock`'s callback queues it, and a one-shot is spent. Nothing runs.
    func fireArmedTimers() {
        for entry in armed where entry.isValid {
            queued.append(entry.body)
            if !entry.repeats { entry.isValid = false }
        }
        armed.removeAll { !$0.isValid }
    }

    /// The main actor runs what was queued, in the order it was queued —
    /// whether or not the timer that queued it has been invalidated since.
    func deliverQueuedBodies() {
        let bodies = queued
        queued = []
        for body in bodies { body() }
    }
}
