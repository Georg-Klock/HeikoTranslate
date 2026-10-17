import Foundation

/// Holds microphone audio back from the network while nobody is speaking.
///
/// OpenAI bills its translation sessions by the minute of audio received,
/// per session, silence included, and the app keeps the microphone open from
/// launch (R4). An hour on the table with nobody talking cost about $4 on
/// OpenAI's price (2026-09). The gate sends audio only around speech:
///
/// - **Closed**, it keeps the last `preRoll` of audio on the phone and sends
///   nothing. Nothing is lost: when speech starts, that pre-roll goes out
///   first, so the soft onset of a word, quieter than the opening threshold,
///   still reaches the model (R4).
/// - **Open**, every chunk is sent. It stays open for `hangover` after the
///   last loud chunk, because the model needs trailing silence to finish
///   the sentence it is translating: OpenAI waits for the end of a clause,
///   and Grok's server VAD needs silence to see the end of a turn.
///
/// Used for OpenAI and Grok only. Gemini's input is its cheap half and its
/// behaviour is measured; it keeps the stream it was measured on.
///
/// Pure (no audio, no clock of its own) so the timing is pinned at L1 and
/// the L3 harness can run the same gate against the live API.
struct AudioGate {

    /// Mic RMS that opens the gate. Below the turn logic's 400 speech floor
    /// on purpose: opening costs a few cents at worst, while opening late
    /// costs the first word. Device measurement 2026-07-29: inter-turn
    /// silence peaks 0-75, speech 991-5263.
    static let openRMS: Double = 250
    /// How long the gate stays open after the last loud chunk.
    static let hangover: TimeInterval = 4.0
    /// How much held audio is sent when the gate opens.
    static let preRoll: TimeInterval = 1.0

    private(set) var isOpen = false
    private var lastLoudAt: Date?
    private var held: [(chunk: Data, at: Date)] = []

    /// Bytes admitted and bytes offered, for the per-run saving line.
    private(set) var sentBytes = 0
    private(set) var offeredBytes = 0

    /// What changed, for the log. Nil when the state did not change.
    enum Transition: Equatable { case opened(preRollChunks: Int), closed }

    /// Offer one mic chunk. Returns the chunks to send now, oldest first,
    /// and whether the gate changed state.
    mutating func admit(_ chunk: Data, rms: Double, at now: Date) -> (send: [Data], transition: Transition?) {
        offeredBytes += chunk.count
        if rms > Self.openRMS { lastLoudAt = now }

        if isOpen {
            if let loud = lastLoudAt, now.timeIntervalSince(loud) <= Self.hangover {
                sentBytes += chunk.count
                return ([chunk], nil)
            }
            isOpen = false
            held = [(chunk, now)]
            return ([], .closed)
        }

        if rms > Self.openRMS {
            isOpen = true
            let out = held.map(\.chunk) + [chunk]
            let preRollCount = held.count
            held = []
            sentBytes += out.reduce(0) { $0 + $1.count }
            return (out, .opened(preRollChunks: preRollCount))
        }

        held.append((chunk, now))
        held.removeAll { now.timeIntervalSince($0.at) > Self.preRoll }
        return ([], nil)
    }

    /// One line for the log: how much audio the network actually got.
    /// 16kHz 16-bit mono is 32000 bytes a second.
    var summary: String {
        let offered = Double(offeredBytes) / 32000, sent = Double(sentBytes) / 32000
        let share = offered > 0 ? Int((sent / offered * 100).rounded()) : 0
        return String(format: "audio gate: sent %.0fs of %.0fs heard (%d%%)", sent, offered, share)
    }
}
