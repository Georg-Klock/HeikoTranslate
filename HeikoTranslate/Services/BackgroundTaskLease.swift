import UIKit

/// A one-shot claim on background execution time, ended exactly once.
///
/// `UIApplication.beginBackgroundTask` hands back an identifier that
/// `endBackgroundTask` must receive exactly once — and two places race to
/// deliver it: the expiration handler iOS calls when time runs out, and the
/// completion of the work the time was bought for. The uploader used to keep
/// that identifier in a mutable local captured by both closures, which read
/// and wrote it from different threads — a data race, and on the wrong
/// interleaving a double-end (GitHub #11). This type is that identifier with
/// the race removed: everything runs on the main actor, and `finish()` is
/// idempotent, so whichever side arrives second finds nothing left to end.
///
/// The two UIKit calls are injected so tests can drive both orderings
/// deterministically; the defaults are the real ones.
@MainActor
final class BackgroundTaskLease {

    typealias BeginTask = (String, @escaping () -> Void) -> UIBackgroundTaskIdentifier
    typealias EndTask = (UIBackgroundTaskIdentifier) -> Void

    private let beginTask: BeginTask
    private let endTask: EndTask
    private var id: UIBackgroundTaskIdentifier = .invalid
    private var onExpire: (() -> Void)?

    init(beginTask: @escaping BeginTask = { name, handler in
             UIApplication.shared.beginBackgroundTask(withName: name,
                                                      expirationHandler: handler)
         },
         endTask: @escaping EndTask = { UIApplication.shared.endBackgroundTask($0) }) {
        self.beginTask = beginTask
        self.endTask = endTask
    }

    /// Claims background time. If iOS calls time before `finish()` does,
    /// `onExpire` runs first — the place to cancel the work the lease was
    /// protecting — and then the task is ended. Either way, once.
    func begin(name: String, onExpire: (() -> Void)? = nil) {
        self.onExpire = onExpire
        id = beginTask(name) { [weak self] in
            // UIKit documents the expiration handler as called synchronously
            // on the main thread; assumeIsolated makes that a checked fact
            // rather than an assumption the compiler can't see.
            MainActor.assumeIsolated {
                self?.expire()
            }
        }
    }

    /// Gives the time back. Safe from either side, any number of times;
    /// only the first call reaches UIKit.
    func finish() {
        onExpire = nil
        guard id != .invalid else { return }
        let ended = id
        id = .invalid
        endTask(ended)
    }

    private func expire() {
        let cancel = onExpire
        onExpire = nil
        cancel?()
        finish()
    }
}
