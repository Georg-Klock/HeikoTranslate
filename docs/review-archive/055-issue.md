# issue #55 — End each diagnostic-upload background task exactly once on a serialized context

- **State:** open
- **Opened by:** Georg-Klock on 2026-08-07T21:37:37Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/55

---

Verified on `main` at `7237cf1fcdfe71c3741e2270c9e829e5a1549f90`.

## Location

- `HeikoTranslate/Services/LogUploader.swift:60-74`

## What's wrong

`task` is a mutable captured local read and written by both the UIKit background-task expiration handler and the `URLSession` completion closure. Those callbacks may run concurrently. Both can observe a non-invalid identifier and both can call `endBackgroundTask`, which is a Swift data race and a double-finish lifecycle bug. The URLSession completion also reaches UIKit lifecycle state without being routed back to the main actor.

## Why it matters — moderate

A diagnostic upload racing background expiration can double-end the task or leave its completion state inconsistent. This is exactly the kind of lifecycle race that becomes intermittent on real devices and is hard to reproduce from logs.

## Suggested fix

Replace the captured mutable identifier with a one-shot lease isolated to the main actor (or an equivalent lock). Route both callbacks through one `finish()` operation:

```swift
@MainActor
private final class BackgroundTaskLease {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "diagnostic-upload") {
            Task { @MainActor in self.finish() }
        }
    }

    func finish() {
        guard id != .invalid else { return }
        let completedID = id
        id = .invalid
        UIApplication.shared.endBackgroundTask(completedID)
    }
}
```

Keep a reference to the URLSession task if expiration should cancel it, then invoke the same `finish()` path. From the URLSession completion, use `Task { @MainActor in lease.finish() }`.

## Acceptance checks

- Simulated expiration followed by network completion ends the background task once.
- Simulated network completion followed by expiration ends it once.
- No UIKit background-task API is invoked from the URLSession callback's arbitrary queue.
- Upload success/failure still records the correct diagnostic result.
