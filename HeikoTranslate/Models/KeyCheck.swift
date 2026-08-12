import Foundation

/// Decides whether an API response proves the embedded key is revoked.
///
/// The distinction matters because the two verdicts lead to opposite advice:
/// a revoked key means THIS BUILD CAN NEVER WORK AGAIN and the only fix is
/// updating the app, while everything else — quota, network, a server having
/// a bad day — heals on its own and should keep the existing "try again"
/// messaging. Telling someone to reinstall over a dead hotel WiFi would be
/// worse than saying nothing, so the classifier only convicts on the two
/// markers Google documents for an invalid key, and treats everything else
/// as inconclusive. GitHub #9.
///
/// Pure, so L1 holds the verdicts against recorded response shapes without
/// the network.
enum KeyCheck {
    enum Verdict: Equatable {
        /// The response names `API_KEY_INVALID`: rotation or revocation.
        case revoked
        /// Anything else — including a healthy response, quota exhaustion,
        /// and garbage. Not proof the key is fine; just not proof it is dead.
        case inconclusive
    }

    /// The machine-readable reason inside `error.details`, and the standard
    /// human message. Either alone convicts; both appear in practice:
    /// `{"error": {..., "status": "INVALID_ARGUMENT",
    ///   "details": [{"reason": "API_KEY_INVALID", ...}]}}`
    private static let markers = ["API_KEY_INVALID", "API key not valid"]

    static func verdict(fromResponseBody body: String) -> Verdict {
        markers.contains(where: body.contains) ? .revoked : .inconclusive
    }
}
