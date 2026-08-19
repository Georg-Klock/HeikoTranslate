import Foundation

/// Which sessions have gone mute: connected, ready, and then silent while a
/// partner kept producing.
///
/// **Measured on device 2026-08-17 (build 2.4.65).** The `de` session
/// completed its handshake and `setupComplete`, then produced ZERO transcripts
/// and zero audio for the whole run. Every turn therefore lacked a home
/// translation, the codes-veto fired correctly on each one, and 20 of 21 turns
/// were rejected over four minutes. Nothing detected it: the startup watchdog
/// only checks that sessions become *ready*, and the server-silence check
/// watches the newest event from ANY session, so a healthy partner kept that
/// clock fresh the entire time.
///
/// The signal that would have caught it — one side empty while the other talks
/// — was in every log line and consulted by nothing.
///
/// Pure, and separate from the service, for the reason the whole model layer
/// is: a watchdog that fires wrongly kills a working session mid-conversation,
/// and that behaviour has to be pinned by tests rather than discovered on a
/// phone.
enum SessionLiveness {

    typealias Lang = TurnLogic.Lang

    /// How recently another session must have produced content for this one's
    /// emptiness to mean anything.
    static let evidenceWindow: TimeInterval = 10

    /// How long a session may produce nothing while a partner produces.
    /// Generous on purpose: a reconnect costs a turn, while the failure it
    /// catches lasts the whole session — so being slow to fire is cheap and
    /// being trigger-happy is not.
    static let muteLimit: TimeInterval = 15

    /// A session that comes back mute twice is saying something a third
    /// reconnect will not fix, and a silent reconnect loop is worse than a
    /// visible failure.
    static let maxReconnects = 2

    /// The sessions that should be torn down and reconnected.
    ///
    /// - `ready`: sessions that completed setup.
    /// - `lastContentAt`: last transcript or audio chunk per session.
    /// - `readyAt`: when each session completed setup — the clock for one that
    ///   has produced *nothing at all*, which is the measured case.
    /// - `reconnects`: mute-driven reconnects already spent per session.
    ///
    /// Returns empty unless another ready session is DEMONSTRABLY producing.
    /// That is the whole discriminator: both sessions transcribe the same
    /// microphone, so in a healthy run both report input transcripts for every
    /// turn and only OUTPUT is legitimately one-sided. Requiring positive
    /// evidence of a live partner separates "this one is broken" from "nobody
    /// has spoken yet", which is what lets this run on a plain 1 Hz beat with
    /// no special case for startup, a quiet room, or a long pause.
    static func muteSessions(ready: Set<Lang>,
                             lastContentAt: [Lang: Date],
                             readyAt: [Lang: Date],
                             reconnects: [Lang: Int],
                             now: Date) -> Set<Lang> {
        guard ready.count > 1 else { return [] }

        let alive = ready.filter { lang in
            guard let at = lastContentAt[lang] else { return false }
            return now.timeIntervalSince(at) < evidenceWindow
        }
        guard !alive.isEmpty else { return [] }

        return ready.subtracting(alive).filter { lang in
            guard reconnects[lang, default: 0] < maxReconnects else { return false }
            // Silent since its last content, or since it became ready if it
            // has never produced any. A session with neither timestamp is not
            // yet judgeable and is left alone.
            guard let since = lastContentAt[lang] ?? readyAt[lang] else { return false }
            return now.timeIntervalSince(since) > muteLimit
        }
    }
}
