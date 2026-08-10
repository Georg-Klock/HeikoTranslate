import Foundation

/// Which session instance is the current one, per language.
///
/// Pure bookkeeping — no audio, no network, no actor — so the rule that
/// decides whether an asynchronous continuation may still act can be tested
/// at L1, the same reason `TurnLogic` exists.
///
/// The problem it solves: the orchestrator routes session events by LANGUAGE
/// (`handle(lang, event)`) and arms reconnect timers per language. Neither
/// carries any notion of *which* session, or which run, it belongs to. That
/// produced three separate bugs with one shape (GitHub #20):
///
/// - A drop-reconnect timer armed before a mute fired after the unmute, when
///   `isRunning` was true again and `dead` had been reset — every guard
///   passed, and it replaced a perfectly healthy session.
/// - Events arriving after `stopSession()` sailed through a pair guard whose
///   `activePair.isEmpty ||` clause was vacuous precisely then.
/// - A replaced session's late `setupComplete` marked its SUCCESSOR ready,
///   which can open the mic before the current session has finished setup —
///   the documented "first utterance silently lost" failure, by the back door.
///
/// Every continuation captures the token current when it was created and
/// checks it before acting. Superseding a session or ending a run makes all
/// of its outstanding continuations inert, without having to find them.
struct SessionRegistry {
    private var tokens: [TurnLogic.Lang: UUID] = [:]

    /// Registers a new session instance for `lang`, superseding any previous
    /// one, and returns the token to capture in its callbacks.
    mutating func register(_ lang: TurnLogic.Lang) -> UUID {
        let token = UUID()
        tokens[lang] = token
        return token
    }

    /// The token a continuation should capture when arming work for `lang`.
    /// `nil` when no session is registered — see `isCurrent`.
    func token(for lang: TurnLogic.Lang) -> UUID? { tokens[lang] }

    /// Whether `token` still refers to the registered session for `lang`.
    ///
    /// A `nil` token is NEVER current, even when nothing is registered. Work
    /// armed while there was no session has nothing to act on, and after
    /// `clear()` a naive `tokens[lang] == token` comparison would make
    /// `nil == nil` true — waving through exactly the stale continuations
    /// this type exists to stop.
    func isCurrent(_ token: UUID?, for lang: TurnLogic.Lang) -> Bool {
        guard let token, let current = tokens[lang] else { return false }
        return token == current
    }

    /// Ends the run. Every token minted before this stops validating, so all
    /// outstanding callbacks and timers from it become inert.
    mutating func clear() { tokens = [:] }
}
