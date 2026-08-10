import XCTest
import UIKit
@testable import HeikoTranslate

/// GitHub #11: the diagnostic upload's background-task identifier was a
/// mutable local captured by two closures racing on different threads — the
/// UIKit expiration handler and the URLSession completion — so
/// `endBackgroundTask` could run twice, or from off the main thread.
/// `BackgroundTaskLease` is the fix; these tests drive both orderings
/// through injected UIKit seams, so the race's interleavings become
/// deterministic cases instead of device-only intermittents.
@MainActor
final class BackgroundTaskLeaseTests: XCTestCase {

    /// Stands in for UIApplication: hands out one identifier, remembers the
    /// expiration handler, and records every end call in order.
    private final class FakeUIKit {
        let issued = UIBackgroundTaskIdentifier(rawValue: 42)
        var beganNames: [String] = []
        var endedIDs: [UIBackgroundTaskIdentifier] = []
        var expirationHandler: (() -> Void)?
        var events: [String] = []

        @MainActor
        func makeLease() -> BackgroundTaskLease {
            BackgroundTaskLease(
                beginTask: { [self] name, handler in
                    beganNames.append(name)
                    expirationHandler = handler
                    return issued
                },
                endTask: { [self] id in
                    endedIDs.append(id)
                    events.append("end")
                })
        }
    }

    // The interleaving the old code handled only by luck: the upload finishes,
    // then iOS's expiration fires anyway.
    func testCompletionThenExpirationEndsOnce() {
        let uikit = FakeUIKit()
        let lease = uikit.makeLease()
        lease.begin(name: "diagnostic-upload")

        lease.finish()               // the URLSession completion arrives first
        uikit.expirationHandler?()   // then iOS calls time anyway

        XCTAssertEqual(uikit.endedIDs, [uikit.issued],
                       "the task must be ended exactly once, with the issued id")
        XCTAssertEqual(uikit.beganNames, ["diagnostic-upload"])
    }

    // The other interleaving: time expires mid-upload, then the (cancelled)
    // upload's completion still reports in.
    func testExpirationThenCompletionEndsOnce() {
        let uikit = FakeUIKit()
        let lease = uikit.makeLease()
        lease.begin(name: "diagnostic-upload")

        uikit.expirationHandler?()   // iOS calls time first
        XCTAssertEqual(uikit.endedIDs.count, 1,
                       "expiration must end the task promptly, not wait for the upload")

        lease.finish()               // the completion arrives late

        XCTAssertEqual(uikit.endedIDs, [uikit.issued],
                       "the late completion must find nothing left to end")
    }

    // Expiration is the moment to abandon the upload: the cancel hook runs
    // exactly once, and before the task is handed back.
    func testExpirationCancelsTheWorkOnceBeforeEnding() {
        let uikit = FakeUIKit()
        let lease = uikit.makeLease()
        var cancels = 0
        lease.begin(name: "diagnostic-upload") {
            cancels += 1
            uikit.events.append("cancel")
        }

        uikit.expirationHandler?()
        uikit.expirationHandler?()   // a defensive second fire must be inert

        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(uikit.events, ["cancel", "end"],
                       "cancel the upload first, then give the time back")
    }

    // A completion that beats expiration must also disarm the cancel hook —
    // finished work must not be cancelled retroactively.
    func testCompletionDisarmsTheCancelHook() {
        let uikit = FakeUIKit()
        let lease = uikit.makeLease()
        var cancels = 0
        lease.begin(name: "diagnostic-upload") { cancels += 1 }

        lease.finish()
        uikit.expirationHandler?()

        XCTAssertEqual(cancels, 0,
                       "an upload that completed must not be cancelled by a late expiration")
        XCTAssertEqual(uikit.endedIDs.count, 1)
    }

    // finish() before begin(), and repeated finish(): both inert.
    func testFinishIsIdempotentAndSafeWithoutBegin() {
        let uikit = FakeUIKit()
        let lease = uikit.makeLease()

        lease.finish()
        XCTAssertEqual(uikit.endedIDs, [], "no task was begun, so none may be ended")

        lease.begin(name: "diagnostic-upload")
        lease.finish()
        lease.finish()
        XCTAssertEqual(uikit.endedIDs, [uikit.issued])
    }
}
