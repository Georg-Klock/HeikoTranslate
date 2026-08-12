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

    /// The PROBE's standard is broader than a frame's, deliberately. A close
    /// reason or error frame convicts only on the key markers above, because
    /// the app cannot know what produced it. The probe is different: the app
    /// built that request itself, well-formed, carrying only the key — so an
    /// auth-flavored rejection IS the answer. Learned on the device
    /// (phone day 2026-08-12, round 3): a scrambled key draws
    /// 401 UNAUTHENTICATED / "invalid authentication credentials", not
    /// API_KEY_INVALID, and the narrow standard called it inconclusive
    /// forever. Quota and network stay inconclusive here too.
    static func verdict(fromProbeBody body: String) -> Verdict {
        if markers.contains(where: body.contains) { return .revoked }
        if body.contains("UNAUTHENTICATED")
            || body.contains("invalid authentication credentials")
            || body.contains("PERMISSION_DENIED") {
            return .revoked
        }
        return .inconclusive
    }

    /// Whether a server-initiated CLOSE looks like an authentication
    /// rejection rather than a network mishap. Learned on the device
    /// (2026-08-12, phone-day case 8): a dead key does NOT fail the
    /// WebSocket upgrade — the handshake completes and the server then
    /// closes 1008 with "Request had invalid authentication credentials",
    /// which is the post-handshake drop path, the one that deliberately
    /// reconnects forever for tunnels and lifts. Suspicion is not
    /// conviction: a close matching this routes into the CAPPED retry
    /// path so the REST probe gets to arbitrate, and the sentence still
    /// only appears when the probe's body convicts.
    static func suspectsAuth(closeReason: String) -> Bool {
        closeReason.contains("invalid authentication credentials")
            || markers.contains(where: closeReason.contains)
    }
}
