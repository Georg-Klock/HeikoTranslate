import Foundation

/// Whether the microphone is still delivering while a run is live. GitHub #129.
///
/// The startup watchdog (#87) only ever asks "has the first buffer arrived?",
/// and the first buffer ends its chain for the rest of the run. So a tap that
/// dies mid-conversation — an engine configuration change after a route
/// change, a hardware reconfiguration, an interruption edge — was never
/// noticed: the button read as listening, both sessions stayed healthy, and
/// speaking did nothing, the state R8 forbids.
///
/// The signal is the buffer **count**, never loudness. A live tap delivers
/// buffers whether or not anyone speaks — about eleven a second on device
/// (2026-08-18 logs, #157) — so a quiet room keeps this healthy and only a tap
/// that has stopped delivering reads as stalled.
///
/// Pure, no clock reads: the service hands in `now` from its injected clock,
/// so L1 drives the whole ladder on a `ManualClock`.
struct MicLiveness: Equatable {
    /// How often the service asks.
    static let checkInterval: TimeInterval = 1.0
    /// No buffers for this long, on a path that has delivered before, is a
    /// stall. Twenty times the measured gap between buffers, and long enough
    /// that an interruption's own notification — which stops the run and
    /// makes this moot — lands first.
    static let stallThreshold: TimeInterval = 2.0
    /// Rebuilds per stall episode before giving up loudly. The same budget
    /// the startup watchdog has (#87).
    static let maxRebuilds = 2

    enum Action: Equatable {
        /// Buffers are arriving.
        case healthy
        /// Nothing has arrived on this run yet: the startup watchdog owns
        /// that case, and acting here too would rebuild twice.
        case notArmed
        /// Stalled: rebuild the audio path. `attempt` counts from 1.
        case rebuild(attempt: Int)
        /// Stalled through every rebuild: stop and say so.
        case giveUp
    }

    private(set) var lastBufferAt: Date?
    private(set) var lastRebuildAt: Date?
    private(set) var rebuilds = 0

    /// One buffer from the tap. Returns true when it ends a stall episode —
    /// a rebuild worked — so the service can log the recovery.
    @discardableResult
    mutating func noteBuffer(at now: Date) -> Bool {
        let recovered = rebuilds > 0
        lastBufferAt = now
        lastRebuildAt = nil
        rebuilds = 0
        return recovered
    }

    /// The periodic question. A rebuild restarts the stall clock from the
    /// moment it ran, so a rebuilt tap gets the full threshold to deliver
    /// before the next attempt — the same grace a cold start gets.
    mutating func check(at now: Date) -> Action {
        guard let lastBuffer = lastBufferAt else { return .notArmed }
        let since = max(lastBuffer, lastRebuildAt ?? .distantPast)
        guard now.timeIntervalSince(since) >= Self.stallThreshold else { return .healthy }
        guard rebuilds < Self.maxRebuilds else { return .giveUp }
        rebuilds += 1
        lastRebuildAt = now
        return .rebuild(attempt: rebuilds)
    }

    /// A new run, or a stopped one. Not called on a rebuild: a rebuilt tap
    /// that comes up dead must still count toward the give-up.
    mutating func reset() {
        self = MicLiveness()
    }
}
