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
    /// Transcript idleness that arms the release — the service's historical
    /// `speechEndPause`, unchanged. The policy owns it now so the harness
    /// and the app cannot drift (#21).
    static let transcriptIdleThreshold: TimeInterval = 1.4

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
}
