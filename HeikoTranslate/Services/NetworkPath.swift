import Foundation
import Network

/// One question, asked once: is this network safe to download a large asset
/// over?
///
/// The service already runs its own long-lived `NWPathMonitor` for the
/// connection-quality banner (SPEC §4.5). This is deliberately NOT that: it is
/// a one-shot read that starts a monitor, takes the first path, and cancels.
/// Sharing the service's monitor would mean reaching into a `@MainActor` type
/// from a detached launch task for a value it does not publish, which is more
/// coupling than one boolean is worth.
enum NetworkPath {

    /// True only when the path is satisfied AND not flagged expensive
    /// (cellular, personal hotspot) or constrained (Low Data Mode). Anything
    /// unknown answers false: the cost of skipping a download is one launch,
    /// and the cost of guessing wrong is someone's cellular allowance.
    static func isUnmetered(timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "NetworkPath.oneshot")
            // The continuation must be resumed exactly once: the handler can
            // fire more than once, and the timeout races it.
            let resumed = OneShot()
            monitor.pathUpdateHandler = { path in
                let ok = path.status == .satisfied && !path.isExpensive && !path.isConstrained
                if resumed.claim() {
                    monitor.cancel()
                    continuation.resume(returning: ok)
                }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.claim() {
                    monitor.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
