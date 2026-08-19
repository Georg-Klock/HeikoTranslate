import Foundation

/// When may "the speaker stopped" fire? The transcript-idle timer proposes;
/// the MICROPHONE disposes. Pure — no timers, no audio — so the L1 tests and
/// the L3 harness run the exact rule the app runs (the FinalizePolicy
/// precedent, GitHub #21).
///
/// Device evidence showed that transcript idleness can lag resumed speech.
/// The microphone signal therefore gets a short veto window. A normally
/// ending turn remains unchanged because the mic is already quiet when the
/// transcript-idle timer fires.
struct SpeechEndPolicy {
    /// Transcript idleness that arms the release. The policy owns it so the
    /// harness and the app cannot drift (#21).
    ///
    /// Was 1.4s, inherited unchanged from the service's `speechEndPause` —
    /// a value chosen when transcript idleness was the ONLY evidence that a
    /// speaker had finished, so it had to be long enough to sit out a breath
    /// on its own. It is not the only evidence any more: since #36/#78 a
    /// speech-level mic buffer vetoes the release outright, and `de_pause`
    /// (one utterance with an internal breath pause) is an L3 case asserting
    /// exactly one release. The conservatism now lives in the microphone,
    /// which is a better instrument for "are they still talking" than a
    /// transcript that arrives late by construction.
    ///
    /// Measured on device 2026-08-18 (build 2.4.76): the pause between the
    /// last transcript and the translation being spoken ran about 3.2s — 1.4s
    /// here plus a very consistent 1.8s of finalization. SPEC §3.3 describes
    /// "quiet for about a second", so this is closing a gap with the stated
    /// design rather than tuning past it.
    static let transcriptIdleThreshold: TimeInterval = 1.2

    /// A speech-level mic buffer within this window of the attempt means
    /// the speaker is still talking. Wider would add latency after every
    /// turn's natural trailing energy; narrower would miss the measured
    /// case (loud buffer 0.148s before the fire).
    static let micQuietWindow: TimeInterval = 0.5

    /// Hard cap on accumulated deferral. A loud room — a restaurant is this
    /// app's natural habitat — must degrade to the OLD behaviour, never
    /// hold a turn open forever. The mic floor (400 RMS) was calibrated on
    /// speech vs silence, not speech vs babble, and no babble log exists
    /// yet to calibrate against; the cap is what makes that ignorance safe.
    static let maxMicExtension: TimeInterval = 2.5

    /// Re-check cadence while deferred.
    static let recheckInterval: TimeInterval = 0.25

    /// Decide at the timer's fire (and at each recheck): may the release
    /// proceed, or is the speaker audibly still going?
    ///
    /// - `lastLoudMicAt`: most recent mic buffer above the speech floor.
    /// - `deferredSince`: when this release attempt FIRST deferred, nil on
    ///   the initial attempt — the babble cap is measured from there.
    static func mayRelease(now: Date, lastLoudMicAt: Date?, deferredSince: Date?) -> Bool {
        guard let loud = lastLoudMicAt,
              now.timeIntervalSince(loud) < micQuietWindow else { return true }
        if let since = deferredSince,
           now.timeIntervalSince(since) >= maxMicExtension { return true }
        return false
    }

    /// GitHub #83, from the device: once `speakerHasStopped` was set, the
    /// microphone was never consulted again until commit — so speech
    /// RESUMING inside that stopped→commit window (~2s) had its first half
    /// committed and its second half dropped as post-commit stragglers,
    /// with the half-sentence translation played over the still-talking
    /// speaker. A loud mic in that window un-stops the turn instead: back
    /// to normal listening, the regular end-of-turn clock re-governs, and
    /// a cough merely re-runs the stop decision one `transcriptIdleThreshold` later.
    ///
    /// `isPlayingOutput` gates the echo: while the loudspeaker is playing
    /// (a previous turn's tail), loudness at the mic proves nothing, and an
    /// un-stop driven by our own voice would hold turns open indefinitely.
    static func speechResumesTurn(speakerHasStopped: Bool,
                                  isPlayingOutput: Bool) -> Bool {
        speakerHasStopped && !isPlayingOutput
    }

}
