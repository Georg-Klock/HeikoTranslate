# issue #2 — Audio-tap closure mutates MainActor-isolated converter state from the real-time audio thread (data race)

- **State:** closed
- **Opened by:** jctoledo on 2026-08-01T23:52:33Z
- **URL:** https://github.com/Georg-Klock/HeikoTranslate/issues/2

---

## Summary
`GeminiLiveTranslationService` is `@MainActor`, but the `AVAudioNodeTapBlock` installed in `startAudioIO()` reads and writes two of its stored properties (`micConverter`, `micConverterInputFormat`) synchronously, *before* ever hopping to `@MainActor`. AVAudioEngine invokes tap blocks on the real-time audio render thread, not the main thread, so this is a genuine unsynchronized cross-thread mutation of shared state — not merely theoretical, since the same properties are also written from the main actor during audio-path rebuilds (`startAudioIO()`/`stopAudioIO()`/the mic watchdog's `checkMicAlive()`).

## Location
`HeikoTranslate/Services/GeminiLiveTranslationService.swift`, around lines 377-387:

```swift
inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
    guard let self else { return }
    if buffer.format != self.micConverterInputFormat {
        guard let rebuilt = AVAudioConverter(from: buffer.format, to: targetFormat) else { return }
        self.micConverter = rebuilt                       // <- written off the main actor
        self.micConverterInputFormat = buffer.format       // <- written off the main actor
        diag("audio", "format changed to \(buffer.format) — converter rebuilt")
    }
    guard let converter = self.micConverter, ...            // <- read off the main actor
```

## Why this compiles without warning
`project.yml` sets `SWIFT_VERSION: "5.0"` with no `SWIFT_STRICT_CONCURRENCY` override — Xcode's default "minimal" concurrency checking, which does not flag actor-isolation violations reached through a plain closure handed to an Objective-C/C callback API like `installTap`. Even if a stricter mode inferred this closure as "MainActor-isolated" from its lexical context, that inference is compile-time bookkeeping only here: `installTap` stores the block and AVAudioEngine invokes it directly from the audio render thread, a path that never goes through Swift's actor executor, so nothing actually forces this code onto the main thread at runtime.

## Failure scenario
The startup/mic watchdog (`checkMicAlive()`, `checkStartupHealth()`) calls `stopAudioIO()` then `startAudioIO()` from the main actor whenever the mic comes up dead — a scenario the code explicitly exists to handle because it happens on real devices (see the `checkMicAlive` doc comment: "on the first start of a process the input tap can deliver *zero* buffers... enabling voice processing reconfigures the input hardware out from under the freshly installed tap"). If a tap invocation is still in flight on the audio thread at that moment — reading `self.micConverter`, or mid-way through the check-then-write format-change branch — while the main actor concurrently reassigns `micConverter`/installs a new tap, the two threads race on the same reference-typed properties. This can hand `Self.convert` a converter that doesn't match the buffer's actual format (garbled/silent audio) or, worst case, an inconsistent/torn reference under ARC.

## Suggested fix
Don't touch `self`'s stored properties synchronously inside the tap block. Capture only the immutable pieces the block needs, or route the converter through a small `Sendable`, lock-protected holder, and only touch `@MainActor` state via a `Task { @MainActor in ... }` hop — the same pattern already used a few lines below for the level/audio-forwarding logic. Worth verifying with Thread Sanitizer once this is testable on a Mac.

## Severity
**High** — real device-triggerable via the mic watchdog's own rebuild path (which exists specifically because it fires on real hardware), racing on audio-critical state.

*Found via code review; independently re-verified before filing (confirmed the compile-time story, the runtime-enforcement gap, and scoped the finding to exactly the two unsafe property writes).*

---

### Georg-Klock — 2026-08-02T03:24:44Z

Fixed in 9c6be51.

Confirmed both halves of the analysis — the render-thread invocation path and the reason it compiles clean under `SWIFT_VERSION 5.0` with default minimal checking.

`micConverter`/`micConverterInputFormat` are gone as stored properties. They now live in `MicConverterBox`, an `@unchecked Sendable` box behind an `NSLock`, owned outside any actor. The tap block's only remaining synchronous access to `self` is the `let` reference to that box; everything else was already behind a `@MainActor` hop.

Two things beyond the minimum:

- The compare-and-rebuild is a single call under one lock, which also closes the check-then-act window the inline version had — the old code could observe a matching format and then use a converter another thread had already replaced.
- The "format changed — converter rebuilt" line moved to the existing main-actor hop. Formatting an `AVAudioFormat` description is an allocation, and the render thread was the wrong place to pay for it. The box reports `didRebuild` so the log still happens, just not on the audio thread.

Not verified under Thread Sanitizer, as you suggested — L1 doesn't exercise the audio path, so TSan would have had nothing to observe. The verification here is structural rather than dynamic: the unsafe accesses are gone by construction. L1 43/43, L3 56/0.
