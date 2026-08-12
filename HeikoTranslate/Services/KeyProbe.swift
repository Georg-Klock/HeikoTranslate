import Foundation

/// One cheap REST request that asks the only question the websocket's
/// handshake failure cannot answer: is the key itself dead?
///
/// A revoked key rejects the WebSocket upgrade before any frame arrives, and
/// from the delegate's seat that is indistinguishable from a captive portal
/// or a blocked route. The models listing endpoint takes the same key over
/// plain HTTPS and, when the key is invalid, says so by name in the body —
/// which `KeyCheck` can then read. Costs nothing, sends nothing but the key
/// the app already holds. GitHub #9.
enum KeyProbe {
    static func currentVerdict() async -> KeyCheck.Verdict {
        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models")!
        components.queryItems = [
            URLQueryItem(name: "key", value: AppConfig.geminiAPIKey),
            URLQueryItem(name: "pageSize", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        // A probe that hangs is a probe that never clears the error banner
        // either way; whatever the network is doing, six seconds is enough
        // to learn what we came for or to give up as inconclusive.
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let body = String(data: data, encoding: .utf8)
        else {
            diag("app", "key probe: no response (network) — inconclusive")
            return .inconclusive
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let verdict = KeyCheck.verdict(fromProbeBody: body)
        // The status and verdict, never the body: it could carry anything,
        // and the log is shareable by design.
        diag("app", "key probe: HTTP \(status) — \(verdict == .revoked ? "revoked" : "inconclusive")")
        return verdict
    }
}
