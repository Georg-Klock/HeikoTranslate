import Foundation

/// What to do when a turn finalizes and `TurnLogic.commit` produced no bubble.
///
/// Pure policy — no timers, no audio, no network — so the **service and the L3
/// replay harness can share it by construction** instead of each keeping its
/// own copy. `CLAUDE.md`: *"Never re-implement app logic … a mirror copy passes
/// forever while the app regresses."* The harness did exactly that, and this is
/// the piece it silently lost.
///
/// The rule itself: a finalize that would DROP the turn because the needed
/// translation has not arrived yet waits instead of giving up (SPEC §5.1,
/// *"keep showing live text and wait"*). Device log 2026-07-29 10:53: English
/// spoken, the English echo present, the German translation still in flight on
/// a starved uplink — finalizing at 1.6s wiped the turn, swallowing the bubble
/// AND its audio. Only *recoverable* rejections wait; an empty original is not
/// going to fill itself in.
///
/// Why it matters that the harness had this and the app did not: measured
/// 2026-08-04 over 19 live `de_after_es` replays, **58% of failures were
/// turn-lost or turn-split** — the exact shape this policy prevents — against
/// 11% genuine mis-attribution. A release gate missing this reports failures
/// the shipping app would not have.
struct FinalizePolicy {
    /// Up to three waits of `deferralInterval` — about six extra seconds.
    /// Beyond that the translation is not coming and holding the turn open
    /// only delays the next one.
    static let maxDeferrals = 3
    static let deferralInterval: TimeInterval = 2.0

    /// How long since the last **input** a deferred retry may still fire. New
    /// speech means the ordinary timers own the turn again, so a retry would
    /// force-finalize mid-sentence — measured as over-segmentation, 3 bubbles
    /// for 2 turns.
    ///
    /// Here rather than written out at both call sites, which is how the two
    /// diverged the first time: sharing `maxDeferrals` and `deferralInterval`
    /// while retyping this one left the harness free to compare against a
    /// different clock, and it did. The clock matters as much as the number —
    /// see the note on `deferredRetryIsDue`. GitHub #21.
    static let speechResumedGuard: TimeInterval = 1.0

    /// Whether a deferral whose interval has elapsed may finalize now.
    ///
    /// `lastInputAt` must be the last time the USER was heard — not the last
    /// time anything happened. The distinction is the whole bug: the app reads
    /// `lastInputAt` (set only from `.inputTranscript`), while the harness read
    /// a `lastContentAt` that the model's own translation text and audio also
    /// bumped. So the very thing the deferral waits for reset the guard, the
    /// retry was skipped, and the harness finalized on a different clock than
    /// the app — with L3 still green. GitHub #21.
    static func deferredRetryIsDue(now: Date, lastInputAt: Date) -> Bool {
        now.timeIntervalSince(lastInputAt) >= speechResumedGuard
    }

    /// Rejections worth waiting on. Both mean "the translation may still be in
    /// flight"; every other reason is terminal for this turn.
    static func isRecoverable(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason.contains("codes-veto") || reason.contains("no session produced")
    }

    enum Outcome: Equatable {
        /// A bubble was produced — emit it and reset.
        case committed
        /// No bubble, but the translation may still arrive. Hold the turn open
        /// and finalize again after `deferralInterval`.
        case waitForTranslation
        /// Nothing more is coming. Reset for the next utterance.
        case giveUp
    }

    private(set) var deferrals = 0

    mutating func decide(committed: Bool, rejectReason: String?) -> Outcome {
        if committed {
            deferrals = 0
            return .committed
        }
        if Self.isRecoverable(rejectReason), deferrals < Self.maxDeferrals {
            deferrals += 1
            return .waitForTranslation
        }
        deferrals = 0
        return .giveUp
    }

    /// Clears the wait count without consulting a rejection — for a stop, a
    /// mute, or any other teardown that abandons the turn outright.
    mutating func reset() { deferrals = 0 }
}
