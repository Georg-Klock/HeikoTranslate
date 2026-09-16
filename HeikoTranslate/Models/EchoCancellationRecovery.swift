import Foundation

/// What the service does when the hardware echo cancellation will not switch
/// on. GitHub #130.
///
/// The full-duplex design depends on it: the microphone keeps streaming while
/// the translation plays, and the voice-processing unit is what stops the app
/// hearing its own voice. Failing to enable it was deliberately not fatal
/// (L1.68d) — running without it beats not running — but it was also
/// invisible. Now it is shown, and retried in the background until it works.
///
/// Pure, no clock reads, so L1 walks the whole schedule on `ManualClock`.
struct EchoCancellationRecovery: Equatable {
    /// Waits before each retry. Escalating and then holding: the app is
    /// usable while degraded, so it never stops trying, but it never storms
    /// the audio hardware either. The same shape as `dropReconnectDelays`.
    static let retryDelays: [TimeInterval] = [3, 10, 30, 60]

    /// A retry rebuilds the audio path, which drops the microphone for a
    /// moment. Never mid-turn: when a retry falls due while someone is
    /// speaking or a translation is playing, look again this soon instead,
    /// without spending an attempt.
    static let busyRecheck: TimeInterval = 1.0

    enum Decision: Equatable {
        case retryNow
        case waitForIdle
    }

    private(set) var attempts = 0

    /// The wait before the next retry.
    var nextDelay: TimeInterval {
        Self.retryDelays[min(attempts, Self.retryDelays.count - 1)]
    }

    /// Whether a due retry may run now. The rebuild behind it is only safe
    /// between turns (R4: speech mid-turn must not fall into the gap).
    static func decide(turnInProgress: Bool, playingOutput: Bool) -> Decision {
        (turnInProgress || playingOutput) ? .waitForIdle : .retryNow
    }

    mutating func noteAttempt() { attempts += 1 }

    /// Echo cancellation is on, or the run is over.
    mutating func reset() { attempts = 0 }
}
