import Foundation

/// Owns the mechanical lifecycle of one locally observed spoken turn.
///
/// `TurnLogic` decides which translation is trustworthy. This type decides
/// whether it is even legal to make that irreversible decision: the current
/// turn must still be current, its speaker must have ended, and both input and
/// output streams must have gone quiet. Keeping that gate pure gives the app
/// and replay harness one testable definition of "may finalize".
struct TurnCoordinator {
    struct ID: Hashable, Comparable {
        private let rawValue: UInt64

        fileprivate init(rawValue: UInt64) {
            self.rawValue = rawValue
        }

        static func < (lhs: ID, rhs: ID) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum Finalization: Equatable {
        /// A timer from a completed or replaced turn fired late.
        case staleTurn
        /// Transcript idleness is only a proposal; the microphone has not
        /// confirmed that the person stopped speaking.
        case speakerStillActive
        case inputStillActive
        case outputStillActive
        case granted
    }

    private var nextID: UInt64 = 0
    private(set) var currentID: ID?
    private(set) var speakerHasStopped = false
    private(set) var lastInputAt = Date.distantPast
    private(set) var lastOutputAt = Date.distantPast

    /// Records user transcript activity. A transcript arriving after an
    /// apparent endpoint re-opens the same turn; only a reset starts a new
    /// turn ID.
    @discardableResult
    mutating func noteInput(at now: Date = Date()) -> ID {
        let id: ID
        if let currentID {
            id = currentID
        } else {
            nextID += 1
            id = ID(rawValue: nextID)
            currentID = id
        }
        lastInputAt = now
        speakerHasStopped = false
        return id
    }

    mutating func noteOutput(at now: Date = Date()) {
        lastOutputAt = now
    }

    /// Seals input for this turn after `SpeechEndPolicy` has allowed it.
    /// Returns false when a timer for an older turn fires after reset.
    @discardableResult
    mutating func confirmSpeakerStopped(for id: ID) -> Bool {
        guard currentID == id else { return false }
        speakerHasStopped = true
        return true
    }

    /// Un-seals a turn the microphone says was sealed too early (GitHub #83).
    /// Deliberately not `noteInput`: `lastInputAt` is server-transcript
    /// timing and feeds the linger and finalize decisions, so loud mic audio
    /// must not advance it. Returns false for a late callback from an older
    /// turn.
    @discardableResult
    mutating func reopenSpeech(for id: ID) -> Bool {
        guard currentID == id else { return false }
        speakerHasStopped = false
        return true
    }

    func isCurrent(_ id: ID) -> Bool {
        currentID == id
    }

    /// The one gate every finalization path must ask before it can commit a
    /// bubble or release translated PCM.
    func finalization(for id: ID, at now: Date = Date(),
                      inputQuietFor: TimeInterval,
                      outputQuietFor: TimeInterval) -> Finalization {
        guard currentID == id else { return .staleTurn }
        guard speakerHasStopped else { return .speakerStillActive }
        guard now.timeIntervalSince(lastInputAt) >= inputQuietFor else {
            return .inputStillActive
        }
        guard now.timeIntervalSince(lastOutputAt) >= outputQuietFor else {
            return .outputStillActive
        }
        return .granted
    }

    /// Invalidates every outstanding timer for the old turn. The next input
    /// receives a new ID, so a late callback becomes a harmless no-op.
    mutating func reset() {
        currentID = nil
        speakerHasStopped = false
        lastInputAt = .distantPast
        lastOutputAt = .distantPast
    }
}
