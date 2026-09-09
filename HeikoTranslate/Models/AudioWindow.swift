import Foundation

/// Sizes an audio window given in SECONDS into the chunk count the service
/// actually caps on. GitHub #131.
///
/// The caps used to be chunk counts calibrated against an assumed 64ms
/// chunk. The tap requests 1024 frames at the hardware rate and takes what
/// it is given, and what it is given is not 64ms: device logs of 2026-08-18
/// count ~11 mic buffers a second (~90ms), while 1024 frames at 48kHz would
/// be 21ms. Either way a fixed count held a different amount of speech than
/// every comment said. The service now reports the first buffer's frames and
/// rate here and re-sizes both windows from it, and the number it measured
/// goes into the log once per run.
enum AudioWindow {
    /// The chunk the counts were originally calibrated against. Used until
    /// the tap reports the real one, so the counts before the first buffer
    /// are exactly the old constants (50 across a reconnect, 250 at launch).
    static let assumedChunkDuration: TimeInterval = 0.064

    /// Chunks needed to span `seconds`, rounded up, never fewer than one. A
    /// non-positive chunk duration falls back to the assumed one rather than
    /// dividing by it.
    static func chunks(spanning seconds: TimeInterval, chunkDuration: TimeInterval) -> Int {
        let duration = chunkDuration > 0 ? chunkDuration : assumedChunkDuration
        return max(1, Int((seconds / duration).rounded(.up)))
    }

    static func chunkDuration(frames: Int, sampleRate: Double) -> TimeInterval? {
        guard frames > 0, sampleRate > 0 else { return nil }
        return Double(frames) / sampleRate
    }
}
