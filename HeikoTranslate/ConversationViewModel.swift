import AVFoundation
import SwiftUI

@MainActor
final class ConversationViewModel: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        /// What was said, in the language it was spoken (shown first).
        let original: String
        /// The spoken-aloud translation (shown below).
        let translation: String
        /// True if the HOME language was spoken — shown on the right.
        let fromHome: Bool
    }

    /// The selected language pair, persisted across launches. Home is the
    /// right side (large type — the phone owner's reader language); partner
    /// is the left. Choosing one equal to the other swaps them, so the pair
    /// is always two distinct languages.
    // The guard below wraps only the *nested* swap assignment, and that
    // placement is the whole point. It used to live inside
    // persistAndApplyLanguages() behind a `defer`, which released it the
    // moment the inner call returned — so the outer observer's own trailing
    // call ran unguarded and one user gesture applied the pair twice. Two
    // applies meant two stop()/beginListening() cycles racing each other:
    // a second installTap on bus 0 (documented to trap) and a second set of
    // sessions overwriting the first without closing them — orphaned sockets
    // still streaming Heiko's audio to Google, still billed, with no
    // reference left that could ever close them. GitHub #1.
    @Published var homeLang: TurnLogic.Lang {
        didSet {
            guard !isAdjustingPair else { return }
            // Belt to the wheel's own filter (#30): home must never become a
            // partner-only language, whatever runtime path writes it. Revert
            // to the previous home, or the default when that is itself
            // unusable. The one path this observer cannot cover — a stored
            // value arriving through init, where observers do not fire — is
            // normalized by init itself (#90).
            if !homeLang.canBeHome {
                withPairAdjustment {
                    homeLang = oldValue.canBeHome ? oldValue : Self.defaultHomeLang
                }
            }
            if homeLang == partnerLang { withPairAdjustment { partnerLang = oldValue } }
            persistAndApplyLanguages()
        }
    }
    @Published var partnerLang: TurnLogic.Lang {
        didSet {
            guard !isAdjustingPair else { return }
            if partnerLang == homeLang {
                // The SPEC §4.4 swap — with one new guard: the old partner
                // may be a partner-only language (#30), which must never
                // take the home side (it has no UI set). The swap then
                // falls back to the default home, or its counterpart when
                // the pick collides with that too.
                let swapped = oldValue.canBeHome ? oldValue
                    : (partnerLang == Self.defaultHomeLang ? Self.defaultPartnerLang
                                                           : Self.defaultHomeLang)
                withPairAdjustment { homeLang = swapped }
            }
            persistAndApplyLanguages()
        }
    }

    /// True only while one observer is assigning the *other* language to keep
    /// the pair distinct. Silences that assignment's observer so the swap
    /// cannot trigger a second apply.
    private var isAdjustingPair = false
    private func withPairAdjustment(_ body: () -> Void) {
        isAdjustingPair = true
        body()
        isAdjustingPair = false
    }

    /// Counts completed applications of the language pair. Exists so a test
    /// can prove one gesture produces exactly one apply — the property that
    /// broke in #1 and cannot be observed from the pure logic layer, because
    /// the bug lived in the observer wiring rather than in any function.
    private(set) var languageApplyCount = 0

    /// What a fresh install opens on: **German as HOME, English as partner.**
    ///
    /// German is home because home is the large line and the right-hand
    /// bubble — the text Heiko actually reads. Shipping this the other way up
    /// gives him an app whose main line is in a language he does not read, and
    /// he cannot be talked through fixing it down a phone line, which is the
    /// whole reason the `-ResetLanguagePair` hatch below exists.
    ///
    /// Named constants rather than literals at the call site so L1.47 can pin
    /// them without reaching into `UserDefaults`. Pinned by product decision,
    /// 2026-08-07.
    static let defaultHomeLang: TurnLogic.Lang = .de
    static let defaultPartnerLang: TurnLogic.Lang = .en

    static func loadLang(_ key: String, default def: TurnLogic.Lang) -> TurnLogic.Lang {
        UserDefaults.standard.string(forKey: key).flatMap(TurnLogic.Lang.init(rawValue:)) ?? def
    }

    /// How long the wheel must sit still before the pair reaches the sessions.
    ///
    /// The settings wheels are rotaries: one flick crosses several notches and
    /// each notch is a language change. Measured on the device 2026-08-07 —
    /// five changes in 240ms — and before this, every one of them tore both
    /// WebSocket sessions down and rebuilt them. That is the GitHub #1 churn
    /// arriving by a new route: the picker that made it impossible was
    /// replaced by a control that makes it easy.
    static let languageSettleDelay: TimeInterval = 0.4

    private var languageRestartTask: Task<Void, Never>?

    /// Counts language changes that actually REACHED the sessions, after
    /// coalescing. Exists so a test can prove one spin restarts once — the
    /// coalescing is the whole point and is otherwise invisible.
    private(set) var languageRestartCount = 0

    private func persistAndApplyLanguages() {
        languageApplyCount += 1
        UserDefaults.standard.set(homeLang.rawValue, forKey: "settings.homeLang")
        UserDefaults.standard.set(partnerLang.rawValue, forKey: "settings.partnerLang")
        diag("app", "language pair set to \(homeLang.rawValue)↔\(partnerLang.rawValue)")
        // Persisting is cheap and happens per change, so the stored pair is
        // always the truth. Only the SESSION RESTART is debounced.
        languageRestartTask?.cancel()
        languageRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.languageSettleDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.languageRestartCount += 1
            guard self.isListening else { return }
            diag("app", "language pair settled — restarting sessions")
            self.stop()
            await self.beginListening()
        }
    }
    @Published private(set) var isListening = false
    @Published private(set) var messages: [Message] = []
    @Published private(set) var activity: GeminiLiveTranslationService.Activity = .idle
    /// Live, word-by-word transcript of what's being said right now, in the
    /// language it's spoken. Cleared when the turn finalizes into a message.
    @Published private(set) var liveTranscript = ""
    /// Which side the in-progress line belongs on: `true` German (right),
    /// `false` foreign (left), `nil` not known yet. While it's nil the line
    /// stays centred and unaligned — guessing produced text that started on
    /// the right and jumped left when the turn finished.
    @Published private(set) var liveIsHome: Bool?
    @Published var errorMessage: String?

    /// Something to say in the slot under the button, and how loudly.
    ///
    /// Severity is DATA. It used to be spelling: the view picked its colour
    /// with `warning.hasPrefix("Schlechte")`, which made the German copy a
    /// control channel — reword the degraded warning and it silently turns
    /// red, with nothing failing and nothing warning. Text and severity are
    /// set together here so they cannot disagree. GitHub #28.
    ///
    /// Named for the slot rather than for connections because two different
    /// things share it now: a connection warning and the microphone notice
    /// below. A mic notice is not a `ConnectionWarning`, and `.info` is not a
    /// severity a connection warning ever has.
    struct StatusNotice: Equatable {
        enum Severity { case info, degraded, lost }
        let text: String
        let severity: Severity
    }

    /// Persistent connection banner (German — Heiko reads it). A CONDITION:
    /// set and cleared by `onConnectionQuality` as the network changes, and it
    /// stays up while the condition holds. Distinct from `errorMessage`, which
    /// is for one-off failures.
    @Published private(set) var connectionWarning: StatusNotice?

    /// Transient notice that the microphone came back on by itself after an
    /// interruption. An EVENT, which is why it is a second property rather
    /// than another value of `connectionWarning`: one is a condition with a
    /// lifetime of its own, and merging them means whichever is set last
    /// clobbers the other. They share the single bottom overlay instead, with
    /// the precedence in `bottomNotice(muted:warning:micNotice:)`.
    ///
    /// Set only after a resume has actually SUCCEEDED — see
    /// `resumeAfterInterruption()`. "The microphone is on again" over a start
    /// that did not happen is worse than saying nothing. GitHub #28.
    @Published private(set) var micNotice: StatusNotice?

    /// How long the mic notice stays up. Generous: Heiko has to notice it and
    /// read it, and it must not become wallpaper.
    static let micNoticeDuration: TimeInterval = 5

    private var micNoticeDismissal: Task<Void, Never>?

    /// Which occupant of the slot under the button wins, in one place.
    ///
    /// The slot can only ever say one thing, and three things want it. Pure so
    /// L1 pins the precedence rather than the view implying it:
    ///
    /// 1. **Muted** — "Mikrofon pausiert" outranks everything; nothing else
    ///    matters while the app is not listening.
    /// 2. **Connection warning** — a condition, up while it holds.
    /// 3. **Mic notice** — a transient event, and the newest arrival, so it
    ///    yields to a standing warning rather than displacing it.
    ///
    /// A second overlay on the same slot, instead of a case here, is how two
    /// messages end up drawn on top of each other. GitHub #28.
    static func bottomNotice(muted: Bool,
                             warning: StatusNotice?,
                             micNotice: StatusNotice?) -> StatusNotice? {
        guard !muted else { return nil }
        return warning ?? micNotice
    }

    /// The whole mapping from connection quality to what the user sees, pure so
    /// L1 can check that severity tracks quality rather than spelling.
    static func warning(for quality: GeminiLiveTranslationService.ConnectionQuality,
                        in lang: TurnLogic.Lang = .de) -> StatusNotice? {
        let s = UIStrings.of(lang)
        switch quality {
        case .good:
            return nil
        case .degraded:
            return StatusNotice(text: s.poorConnection, severity: .degraded)
        case .silent:
            return StatusNotice(text: s.noServerResponse, severity: .lost)
        case .offline:
            return StatusNotice(text: s.offline, severity: .lost)
        }
    }

    /// Whether an `AVAudioSession` interruption-ended notification says iOS
    /// considers resuming appropriate.
    ///
    /// **Diagnostic, not a gate.** An earlier draft of #28 used this to stay
    /// paused whenever iOS withheld `.shouldResume`. That was reversed on a
    /// product decision: iOS almost always attaches an options value, so the
    /// real effect was that any interruption it did not mark resumable — an
    /// alarm or a timer, the common case — left Heiko permanently muted until
    /// he noticed and tapped. For this user a silent stop he does not notice
    /// is worse than an unexpected start he can see. So the app resumes
    /// anyway, tells him it did, and records what iOS thought in the device
    /// log. Pure, so L1 covers it without an audio session. GitHub #28.
    static func mayResume(afterInterruptionOptions raw: UInt?) -> Bool {
        guard let raw else { return true }
        return AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
    }

    /// False until the user has started listening at least once. The app
    /// deliberately opens muted (see `ContentView.task`) while the
    /// speak-immediately-at-launch bug is outstanding, so this distinguishes
    /// "waiting to be started" from "the user muted it".
    @Published private(set) var hasEverStarted = false

    /// True while a start attempt is in flight (permission prompt, connect).
    @Published private(set) var isLaunching = false

    /// The one pending start attempt, and the stamp that says whether it is
    /// still current. GitHub #13: every trigger used to spawn its own
    /// unstructured `Task { beginListening() }`, so two taps during a slow
    /// permission prompt awaited the gate concurrently and BOTH called
    /// `start()` — the second silently tearing down and rebuilding the
    /// first's live run — and a prompt still up while the app backgrounded
    /// could return and open the microphone with the app not on screen.
    /// The task is owned so invalidation can cancel it; the generation is
    /// what a start that survives its await checks before touching anything,
    /// because the world it was started in may be gone.
    private var startTask: Task<Void, Never>?
    private var startGeneration = 0

    /// The ONE scheduling path for every spawned start trigger — the tap, the
    /// scene-active resume, the interruption-ended resume. Stamps the task
    /// with the generation current at scheduling time and re-checks it at the
    /// task's first actor turn, because cancellation alone cannot be trusted
    /// there: it is cooperative, and a task cancelled before it ever ran still
    /// enters its body. Before this stamp, a tap immediately followed by
    /// backgrounding produced exactly that task — it set `isLaunching`, minted
    /// a fresh generation that made the stale-grant guard pass, requested
    /// permission, and its post-await early return left the UI launching
    /// forever, turning every future tap into the deliberate no-op branch.
    /// A superseded start must instead do NOTHING: no launch state, no
    /// generation, no prompt, no microphone. GitHub #13.
    private func scheduleStart(resume: Bool = false) {
        let stamp = startGeneration
        startTask = Task { [weak self] in
            guard let self else { return }
            guard stamp == self.startGeneration, !Task.isCancelled else {
                diag("app", "scheduled start superseded before it ran — not starting")
                return
            }
            // Scene eligibility at task entry: the scene can leave between
            // scheduling and the first actor turn, and audio work must not
            // start while the app is not active. A superseded automatic
            // resume is handed BACK to the armed flag so `.active` performs
            // it — dropping it left the app muted with nobody owed a start
            // (R8). A superseded tap is dropped: the user left; a fresh tap
            // owns the next start. GitHub #13.
            guard self.sceneIsActive else {
                diag("app", "scheduled start arrived while the scene is not active — \(resume ? "re-arming for .active" : "dropping")")
                if resume { self.resumeWhenActive = true }
                return
            }
            if resume {
                await self.resumeAfterInterruption()
            } else {
                await self.beginListening()
            }
        }
    }

    /// Whether the scene is `.active` — the eligibility every automatic
    /// start checks at scheduling, at task entry, and after the permission
    /// await. `.inactive` counts as not active: it is where the app sits
    /// while the system permission alert is up, while the app switcher
    /// peeks, and on the way to background. Starts are DEFERRED there, never
    /// performed. Defaults to true because the view model is built for a
    /// scene that is being brought to the foreground. GitHub #13.
    private(set) var sceneIsActive = true

    /// Counts calls that actually reached the service-start step. Exists so a
    /// test can prove two rapid taps produce exactly ONE start and a
    /// backgrounded prompt produces ZERO — the properties that broke in #13,
    /// invisible from outside for the same reason `languageApplyCount` and
    /// `automaticResumeCount` exist. GitHub #13.
    private(set) var serviceStartCount = 0

    #if DEBUG
    /// Test seams (GitHub #13): stand-ins for the permission prompt and the
    /// real service start, so the start path's interleavings — the delayed
    /// grant, the grant arriving after backgrounding — can be driven
    /// deterministically. `nil` (the shipping state) means the real thing.
    var permissionRequestForTesting: (() async -> Bool)?
    var serviceStartForTesting: (() -> Bool)?
    #endif

    /// Set when listening was stopped by the system (backgrounding, a phone
    /// call, Siri) rather than by the user — so the app resumes by itself
    /// when it becomes active again instead of sitting muted (R8).
    ///
    /// Set by the two automatic pause paths — backgrounding, and an audio
    /// interruption — and by the scene-eligibility deferrals, which hand a
    /// start that may not perform while the scene is not active back to the
    /// `.active` path (GitHub #13). Cleared by exactly two things: consuming
    /// it, and a manual tap in either direction.
    ///
    /// The bug that made this an invariant worth writing down: an interruption
    /// armed it, the user started listening again by hand, and the flag was
    /// still set — so the next resume trigger fired a SECOND `beginListening()`
    /// the user never asked for, mid-conversation. Whoever changes the session
    /// state by hand owns the flag. `private(set)` so a test can see it.
    /// GitHub #28.
    private(set) var resumeWhenActive = false

    /// Counts automatic resumes this view model has decided to perform — the
    /// ones no tap asked for. Exists so a test can prove the ownership rule
    /// yields *exactly one* start across an interruption, the property that
    /// broke in #28; same reason `languageApplyCount` exists for #1.
    private(set) var automaticResumeCount = 0

    /// Shown under the button before the very first tap — Heiko reads German.
    ///
    /// Suppressed while an error is showing. On a denied microphone permission
    /// `hasEverStarted` stays false, so this hint used to sit on screen next to
    /// "Bitte erlaube Mikrofonzugriff…" — one line saying tap to speak, the
    /// other saying tapping will not work, permanently, since iOS only prompts
    /// once. That is the app's most likely first-run failure and its target
    /// user is the least able to recover from it. GitHub #25.
    var startHint: String? {
        guard errorMessage == nil else { return nil }
        return (!isListening && !hasEverStarted && !isLaunching) ? strings.tapToSpeak : nil
    }

    /// True once the microphone has been refused. iOS only ever prompts once,
    /// so this is terminal until the user changes it in Settings — which makes
    /// the one button's job "take me there" rather than "try again". SPEC R8:
    /// never sit in a state where the obvious action does nothing.
    ///
    /// Cleared on the way back from Settings — see `noteMicPermission(granted:)`.
    /// Nothing cleared it before, so recovery depended entirely on iOS
    /// terminating the app when the microphone switch is toggled. It usually
    /// does; the case it does not cover is Heiko opening Settings, not
    /// understanding it, and backing out — after which the one button was
    /// permanently a Settings shortcut and could never start listening again.
    /// GitHub #25.
    @Published private(set) var micPermissionDenied = false

    #if DEBUG
    /// Reaching the denied state for real needs a permission prompt, which a
    /// test cannot answer. DEBUG-only so it cannot be called from shipping code.
    func forceMicPermissionDeniedForTesting() { micPermissionDenied = true }
    #endif

    /// The embedded key is revoked (GitHub #9). Terminal like a denied
    /// permission, and handled the same way: the one button stops trying to
    /// listen and opens the update page instead. Never cleared — a revoked
    /// key cannot come back; only an updated build can.
    @Published private(set) var keyRevoked = false

    /// The confirmation step between "connections keep failing" and "tell
    /// the user this build is dead". Tests substitute a canned verdict; the
    /// real closure asks the API over REST (`KeyProbe`), because convicting
    /// the key on connection failures alone would show "update the app" to
    /// anyone on airport WiFi.
    var keyProbeForTesting: (() async -> KeyCheck.Verdict)?

    private var keyConfirmationTask: Task<Void, Never>?

    /// Every service error funnels here — a named method rather than
    /// closure body so the test seam drives the identical code, not a copy.
    private func handleServiceError(_ message: String) {
        // A server that names API_KEY_INVALID outright has already answered
        // what the probe would ask. GitHub #9.
        if KeyCheck.verdict(fromResponseBody: message) == .revoked {
            noteKeyRevoked("server error frame")
            return
        }
        // An auth-flavored rejection starts the probe NOW, not after the
        // retry ladder: on the device the ladder needs ~17s of "Verbinde…"
        // to exhaust, and the person at the phone taps long before that
        // (phone day 2026-08-12). The generic line still shows while the
        // probe runs — suspicion is not conviction.
        if KeyCheck.suspectsAuth(closeReason: message) {
            confirmKeyNow("auth-suspect session error")
        }
        errorMessage = strings.connectionError
        print("GeminiLiveTranslationService error: \(message)")
    }

    /// What `onSessionsExhausted` runs.
    private func handleSessionsExhausted() {
        stop()
        // The belt to the immediate path above: whatever exhausted the
        // retries, one probe settles whether an update is the only fix.
        confirmKeyNow("post-exhaustion probe")
    }

    /// One probe in flight at a time; conviction is permanent, an
    /// inconclusive verdict clears the latch so a later suspicion (or the
    /// exhausted belt) can ask again once the network is back.
    private func confirmKeyNow(_ evidence: String) {
        guard !keyRevoked, keyConfirmationTask == nil else { return }
        let probe = keyProbeForTesting ?? KeyProbe.currentVerdict
        keyConfirmationTask = Task { @MainActor [weak self] in
            if await probe() == .revoked { self?.noteKeyRevoked(evidence) }
            self?.keyConfirmationTask = nil
        }
    }

    /// What `onMicUnrecoverable` runs: the watchdog spent both rebuilds and
    /// the microphone still delivers nothing, so the service has already torn
    /// itself down. `stop()` moves the BUTTON to the tap-to-start state (its
    /// second `stopSession()` is redundant but harmless — same shape as the
    /// exhausted-pair handler above), and the sentence is the existing
    /// reviewed one for "the app tried to restart the microphone by itself
    /// and could not": actionable, because the reader was not at the button
    /// when this happened. Same errorMessage-over-muted pairing the failed
    /// automatic resume uses (GitHub #5). No new copy. GitHub #87, SPEC R8.
    private func handleMicUnrecoverable() {
        stop()
        errorMessage = strings.micResumeFailed
    }

    #if DEBUG
    /// Reaching the exhausted state for real needs failed connections
    /// against a live socket. DEBUG-only, same code path.
    func forceSessionsExhaustedForTesting() { handleSessionsExhausted() }
    /// The mic give-up handler, reachable without a dead audio graph.
    /// DEBUG-only, same code path. GitHub #87.
    func forceMicUnrecoverableForTesting() { handleMicUnrecoverable() }
    /// The service-error funnel, reachable without a socket. DEBUG-only.
    func reportServiceErrorForTesting(_ message: String) { handleServiceError(message) }
    /// Lets a test wait for the probe verdict instead of sleeping.
    func awaitKeyConfirmationForTesting() async { await keyConfirmationTask?.value }
    #endif

    private func noteKeyRevoked(_ evidence: String) {
        guard !keyRevoked else { return }
        diag("app", "API key revoked (\(evidence)) — showing the update sentence, no more retries")
        keyRevoked = true
        errorMessage = strings.updateRequired
        stop()
    }

    /// Opens the update page. Soft on a missing URL by design: a build
    /// without `APP_UPDATE_URL` keeps showing the sentence, and the tap
    /// stays a no-op rather than a crash or a lie in the log.
    private func openUpdatePage() {
        guard let url = AppConfig.appUpdateURL else {
            diag("app", "update tap with no APP_UPDATE_URL configured — nowhere to send it")
            return
        }
        UIApplication.shared.open(url)
    }

    /// Fold a fresh reading of the microphone permission into the denial state.
    /// Split from the scene-phase handler so L1 can exercise it without an
    /// audio session — the branch is otherwise unreachable from a test, which
    /// is how it shipped unexercised in the first place.
    func noteMicPermission(granted: Bool) {
        guard micPermissionDenied, granted else { return }
        diag("app", "microphone permission granted while we were away — recovering")
        micPermissionDenied = false
        errorMessage = nil
    }

    /// Everything the user reads, in the HOME language — the right-hand
    /// bubble, which is the phone owner's own. Not the system locale: the app
    /// already asked which language is theirs, on the home wheel.
    var strings: UIStrings { UIStrings.of(homeLang) }

    /// Status line under the mic.
    var statusText: String {
        // A revoked key shows ONE sentence. "Verbinde…" beside it is a
        // promise the app cannot keep, and "Mikrofon pausiert" an
        // invitation to a tap that cannot help — device finding,
        // phone day 2026-08-12. GitHub #9.
        if keyRevoked { return "" }
        if !isListening {
            if isLaunching { return strings.connecting }
            return hasEverStarted ? strings.micPaused : ""
        }
        switch activity {
        case .connecting: return strings.connecting
        case .understanding: return strings.hearing
        case .translating: return strings.translating
        case .idle: return ""
        }
    }

    var statusIsPaused: Bool { !isListening && !isLaunching }

    /// True only while the "Mikrofon pausiert" NOTICE is actually on screen —
    /// the one status that outranks the connection warning in the slot
    /// above the button. (statusIsPaused alone is also true before the very
    /// first tap, when the slot is blank.)
    ///
    /// Scope note: this is the NOTICE only. The mic glyph's amber-and-struck
    /// -through appearance is a separate rule — see `micReadsAsMuted` — and
    /// the two deliberately disagree on a cold launch. They were briefly one
    /// property; Georg's decision on 2026-08-07 split them again.
    var statusShowsMuted: Bool {
        Self.readsAsMuted(isListening: isListening,
                          isLaunching: isLaunching,
                          hasEverStarted: hasEverStarted)
    }

    /// Whether the app should present itself as MUTED, as a pure function of
    /// the three flags that decide it.
    ///
    /// Extracted for the reason `bottomNotice` and `mayResume` were: the rule
    /// is then a thing a test can hold, over states an instance cannot easily
    /// be put into (mid-launch, listening) without audio hardware. The
    /// distinction it draws is invisible in every state but one — a cold
    /// launch — which is how three call sites read `statusIsPaused` for six
    /// review rounds without anything failing.
    ///
    /// **Muted means the user turned it off**, so it requires a session the
    /// user actually started. Never started, or still starting, is not muted.
    /// GitHub #43.
    static func readsAsMuted(isListening: Bool, isLaunching: Bool, hasEverStarted: Bool) -> Bool {
        guard !isListening, !isLaunching else { return false }
        return hasEverStarted
    }

    /// Whether the MIC GLYPH draws itself muted — amber, struck through.
    ///
    /// **This is true on a cold launch, and that is deliberate.** It is the
    /// app's resting face: a microphone that is plainly off, with "Zum
    /// Sprechen antippen" beside it saying how to turn it on. Product decision,
    /// 2026-08-07, after seeing the alternative on his phone.
    ///
    /// It was briefly keyed to `statusShowsMuted`, on the reasoning that a
    /// struck-through mic above an invitation to speak is a contradiction.
    /// The founder's read is the opposite: the slash is what MAKES the
    /// invitation legible — it shows the state the tap is going to change.
    /// A plain white mic before the first tap looks like a mic that is
    /// already listening, which is the more expensive misreading of the two.
    ///
    /// Recorded at this length because the last two sessions each treated
    /// this as a defect. It is a decision.
    ///
    /// Note it does NOT depend on `hasEverStarted` — that is the whole
    /// difference from `readsAsMuted`, and the only state where they differ.
    static func glyphReadsAsMuted(isListening: Bool, isLaunching: Bool) -> Bool {
        !isListening && !isLaunching
    }

    /// The mic glyph's muted appearance. See `glyphReadsAsMuted`.
    var micReadsAsMuted: Bool {
        Self.glyphReadsAsMuted(isListening: isListening, isLaunching: isLaunching)
    }

    /// True while the sessions are still connecting — show a loading spinner.
    var isConnecting: Bool { isListening && activity == .connecting }

    /// True while the translation is being spoken aloud — drives the
    /// outward ripples, visually distinct from the voice-driven listening
    /// rings so "hearing you" and "talking to you" read differently at a
    /// glance across a table.
    var isSpeaking: Bool { isListening && activity == .translating }

    /// Live microphone loudness, 0...1. Drives the flag directly so the app
    /// reacts the instant someone speaks, without waiting for the API.
    @Published private(set) var micLevel: Double = 0

    private let translator = GeminiLiveTranslationService()

    /// The single control: tap to start listening, tap again to mute.
    /// Starting always goes through the permission gate — after a denial,
    /// tapping the one button must re-explain the Settings fix instead of
    /// silently doing nothing forever (R8).
    func toggleButton() {
        diag("ui", "button tapped (listening=\(isListening))")
        // Denied permission is terminal until Settings changes it, so the one
        // control opens Settings instead of re-running a request iOS will
        // never show again. Deliberately still ONE button doing one thing at a
        // time — the alternative was adding a second control to a single-button
        // app, or leaving Heiko tapping something that cannot work. GitHub #25.
        if keyRevoked {
            diag("ui", "tap while the key is revoked — opening the update page")
            openUpdatePage()
            return
        }
        if micPermissionDenied {
            diag("ui", "opening Settings for the denied microphone permission")
            openSettings()
            return
        }
        noteManualToggle()
        if isListening {
            stop()
        } else if isLaunching {
            // A tap while a start is already pending is a no-op, explicitly:
            // the likely cause is an accidental double-tap, and for this
            // user "double-tapped and it still ends up listening" beats
            // "double-tapped and it silently cancelled". The spinner is
            // already saying Verbinde…; the pending start owns the session.
            // GitHub #13.
            diag("ui", "tap while a start is pending — the pending start owns it")
        } else {
            // The tap owns the next start outright: an automatic resume that
            // was QUEUED but has not yet run (its task holds a still-current
            // generation) must not race it and win, showing automatic-resume
            // behaviour for a start the user just took by hand. The bump
            // supersedes any queued task; the manual start is the only one
            // left standing. GitHub #13.
            invalidatePendingStart()
            scheduleStart()
        }
    }

    /// A tap in either direction takes ownership of the session: a pending
    /// automatic resume from an earlier interruption is consumed here rather
    /// than left armed to fire a second start later, and a mic notice from a
    /// previous resume goes with it — it must never linger over a state the
    /// user has since changed by hand. GitHub #28.
    func noteManualToggle() {
        resumeWhenActive = false
        clearMicNotice()
        // A tap owns the session, so a language restart still waiting to fire
        // must not arrive afterwards and start something the user just stopped.
        languageRestartTask?.cancel()
    }

    /// Opens this app's page in iOS Settings, where the microphone switch is.
    /// UIApplication.openSettingsURLString lands directly on the app's own
    /// pane — Heiko never has to find it by name in a list he cannot read.
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Ensures mic permission, then starts listening. Called on every unmute
    /// and when resuming after an interruption.
    func beginListening() async {
        // A revoked key is terminal for this build — an automatic resume
        // restarting the doomed connect-retry-fail loop would replace the
        // update sentence with "Verbinde…", which is a promise the app
        // cannot keep. GitHub #9.
        guard !keyRevoked else {
            diag("app", "start requested while the key is revoked — refusing; only an update fixes this")
            return
        }
        // One start at a time: a second trigger while one is pending (a
        // double-tap racing an automatic resume, two resume paths firing)
        // must not run the gate concurrently — two grants both called
        // start(), and the second tore down the first's live run. GitHub #13.
        guard !isLaunching else {
            diag("app", "start already pending — ignoring a second trigger")
            return
        }
        isLaunching = true
        startGeneration &+= 1
        let generation = startGeneration
        let granted: Bool
        #if DEBUG
        if let stub = permissionRequestForTesting {
            granted = await stub()
        } else {
            granted = await translator.requestPermissions()
        }
        #else
        granted = await translator.requestPermissions()
        #endif
        // The world can move on while the prompt is up: backgrounding or a
        // stop invalidates pending starts. A stale grant does nothing — most
        // of all it does not open the microphone with the app off screen —
        // and it must not touch `isLaunching`, which now belongs to whoever
        // is current. GitHub #13.
        guard generation == startGeneration else {
            diag("app", "pending start invalidated while awaiting permission — not starting")
            return
        }
        // Generation intact but the task itself was cancelled: nobody
        // invalidated (that always bumps the generation), so the launch state
        // is still THIS start's to release — leaving it set turned every
        // future tap into the no-op branch. GitHub #13.
        guard !Task.isCancelled else {
            diag("app", "pending start cancelled while awaiting permission — not starting")
            isLaunching = false
            return
        }
        isLaunching = false
        guard granted else {
            diag("app", "microphone permission DENIED")
            micPermissionDenied = true
            errorMessage = strings.micDenied
            return
        }
        // The scene left while the prompt was up. This is the NORMAL
        // first-run shape, not an edge: the system permission alert itself
        // puts the scene in .inactive, and the grant can resolve before the
        // reactivation is delivered. Zero audio work while not active — the
        // granted intent is handed to the `.active` path, which starts the
        // moment the scene returns (for the alert case, immediately).
        // Background never reaches here: it invalidates the generation
        // outright, and deliberately without a resume. GitHub #13.
        guard sceneIsActive else {
            diag("app", "permission granted while the scene is not active — deferring the start to .active")
            resumeWhenActive = true
            return
        }
        hasEverStarted = true
        start()
    }

    /// Any pending start attempt is now void — the state it was started in
    /// is gone. Bumping the generation is what a stale await checks; the
    /// cancel is for the owned task on top. GitHub #13.
    private func invalidatePendingStart() {
        startGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        isLaunching = false
    }

    /// Ask for the microphone at launch so the first tap goes straight into
    /// listening rather than stopping for a system prompt.
    func prepareAtLaunch() async {
        _ = await translator.requestPermissions()
    }

    /// System took the audio away (backgrounded, phone call, Siri) or gave
    /// it back. User intent is unchanged, so listening resumes by itself.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            diag("app", "backgrounded (listening=\(isListening))")
            sceneIsActive = false
            DiagnosticLog.shared.flush()
            // A permission prompt still up when the app leaves the screen
            // must not come back granted and start audio and sockets while
            // the app is backgrounded. The user starts fresh on return —
            // deliberately no auto-resume for a start that never happened.
            // GitHub #13.
            invalidatePendingStart()
            if isListening {
                resumeWhenActive = true
                stop()
            }
        case .active:
            diag("app", "foregrounded (resume=\(resumeWhenActive))")
            sceneIsActive = true
            // Coming back from Settings is the one moment the answer can have
            // changed without us asking. Reading it is free and does not
            // prompt. GitHub #25.
            noteMicPermission(granted: AVAudioApplication.shared.recordPermission == .granted)
            if noteBecameActive() {
                scheduleStart()
            }
        case .inactive:
            // The alert-and-app-switcher state. Deliberately invalidates
            // NOTHING — the permission alert itself puts the scene here, so
            // a pending tap-started prompt must survive it. What .inactive
            // does change: no start may PERFORM while it holds; grants and
            // resumes arriving now are deferred to `.active` through the
            // armed flag. GitHub #13.
            diag("app", "scene inactive")
            sceneIsActive = false
        @unknown default:
            break
        }
    }

    /// Foreground resume. Deliberately shows **no** notice: backgrounding is
    /// frequent and self-inflicted — Heiko put the app away himself — and a
    /// banner on every app switch becomes wallpaper he stops reading. If it
    /// should appear here too, this is the one line to change. GitHub #28.
    @discardableResult
    func noteBecameActive() -> Bool { claimPendingResume() }

    /// Internal, not private, so a test can drive the FULL production
    /// sequence — including the resume task this schedules on `.ended`, which
    /// is exactly the piece a seam-only test cannot reach. GitHub #13.
    func handleAudioInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        // Thin caller: every decision below is in the seam, so the whole
        // ownership sequence is reachable from a test. GitHub #28.
        switch type {
        case .began:
            if noteInterruptionBegan() { stop() }
        case .ended:
            if noteInterruptionEnded(options: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) {
                // Through the owned path, not a loose Task: a background or a
                // new interruption arriving before this resume gets its first
                // actor turn must be able to void it. GitHub #13.
                scheduleStart(resume: true)
            }
        @unknown default:
            break
        }
    }

    /// iOS took the audio away mid-conversation. Returns whether it armed an
    /// automatic resume; the caller tears the session down. Split that way so
    /// the arming is reachable from a test without an audio session.
    @discardableResult
    func noteInterruptionBegan() -> Bool {
        diag("app", "audio interrupted (call/Siri/alarm)")
        // A start still awaiting the permission prompt is voided outright: a
        // grant arriving mid-interruption must not open the microphone and
        // sockets while iOS owns the audio. Deliberately before the listening
        // guard — the pending state is exactly the one where isListening is
        // still false — and no resume is armed for it: a session that never
        // started earns none. GitHub #13.
        invalidatePendingStart()
        guard isListening else { return false }
        resumeWhenActive = true
        return true
    }

    #if DEBUG
    /// Test seam for the interruption sequence. Arming requires a live
    /// session, and starting one needs audio hardware a unit test cannot
    /// have — so this forces that single precondition and then runs the REAL
    /// arming path. It touches no audio session: the app's own handler is
    /// what calls `stop()`.
    func simulateInterruptionBeganForTesting() {
        isListening = true
        noteInterruptionBegan()
        isListening = false
    }

    /// Test seam: stand in for a live session so `toggleButton()` takes its
    /// stop branch, which is the one that needs no network. Sets the published
    /// flag only.
    func forceListeningForTesting() { isListening = true }
    #endif

    /// iOS gave the audio back. Returns whether an automatic resume is owed —
    /// the CALLER performs it. Keeping the decision free of the audio session
    /// is what makes the arm → manual start → resume-trigger sequence testable
    /// at all; it was unreachable before, and the failure mode it guards is
    /// the microphone opening without the user asking. GitHub #28.
    @discardableResult
    func noteInterruptionEnded(options raw: UInt?) -> Bool {
        // Recorded, not obeyed — see `mayResume(afterInterruptionOptions:)`
        // for why this stopped being a gate. The device log still says what
        // iOS thought, so the decision stays reviewable against real traffic.
        diag("app", "interruption ended (iOS shouldResume=\(Self.mayResume(afterInterruptionOptions: raw)))")
        // An interruption that ends while the app is NOT active — the call
        // was taken, the app was backgrounded mid-call, then the call ended —
        // must not restart microphone and network work off-screen. The
        // resume is deferred, not consumed: the flag stays armed and the
        // `.active` path claims it when the app returns. GitHub #13.
        guard sceneIsActive else {
            diag("app", "interruption ended while the scene is not active — resume deferred to .active")
            return false
        }
        return claimPendingResume()
    }

    /// Consume the armed flag, counting the resume. The single place the flag
    /// is spent, so "exactly one start" is a property of one function.
    private func claimPendingResume() -> Bool {
        guard resumeWhenActive else { return false }
        resumeWhenActive = false
        automaticResumeCount += 1
        return true
    }

    /// Resume after an interruption, and say so — but only if it worked.
    ///
    /// `beginListening()` can fail on permission or an audio session that
    /// genuinely cannot activate, which is the case iOS was hinting at when it
    /// withheld `.shouldResume`. Honouring the product decision to resume
    /// anyway makes that path reachable, so the notice waits for the outcome
    /// rather than announcing an intention. GitHub #28.
    private func resumeAfterInterruption() async {
        await beginListening()
        noteAutomaticResumeFinished(started: isListening)
    }

    /// The outcome half of an automatic resume, split out so the rule "notice
    /// only if it actually started" is a function with a test rather than an
    /// ordering inside an async body. `showMicNotice()`'s only caller in the
    /// app is behind this guard. GitHub #28.
    func noteAutomaticResumeFinished(started: Bool) {
        guard started else {
            diag("app", "automatic resume after interruption did NOT start — showing the tap prompt")
            // The one user least able to infer an action gets one: the app
            // failed HIM, not the other way round, and the button is the
            // recovery. errorMessage, not a micNotice — the failed state has
            // statusShowsMuted true, and the notice slot's precedence
            // (muted > warning > notice) would never render a notice here.
            // A later successful start clears it (start() begins with
            // errorMessage = nil). Approved copy, 2026-08-06. GitHub #5.
            errorMessage = strings.micResumeFailed
            return
        }
        diag("app", "resumed automatically after an interruption")
        // A resume that STARTED leaves no failure prompt behind. In the app
        // this is already true — the successful start() cleared it — but the
        // rule belongs to this seam, where L1.41e can hold it without a real
        // start. GitHub #5.
        errorMessage = nil
        showMicNotice()
    }

    /// Raise the notice and start its dismissal clock. Internal rather than
    /// private so L1 can check what it puts on screen; the only caller in the
    /// app is `resumeAfterInterruption()`, after a start has succeeded.
    func showMicNotice() {
        micNoticeDismissal?.cancel()
        micNotice = StatusNotice(text: strings.micResumed, severity: .info)
        micNoticeDismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.micNoticeDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clearMicNotice()
        }
    }

    /// Take the notice down and cancel its timer. Idempotent, so every path
    /// that ends the resumed state can call it without checking first.
    func clearMicNotice() {
        micNoticeDismissal?.cancel()
        micNoticeDismissal = nil
        micNotice = nil
    }

    /// Fills the transcript with a sample conversation so layout work can be
    /// checked in the Simulator without anyone talking. DEBUG only, opt-in:
    ///   xcrun simctl launch booted com.klock.heikotranslate -UITestSeed YES
    private func seedSampleConversationIfRequested() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "UITestBanner") {
            connectionWarning = Self.warning(for: .degraded, in: homeLang)
        }
        guard UserDefaults.standard.bool(forKey: "UITestSeed") else { return }
        messages = [
            Message(original: "Hallo, ich hätte gerne einen großen Hamburger mit extra Salat.",
                    translation: "Hi, I'd like a large hamburger with extra lettuce.", fromHome: true),
            Message(original: "That will cost you about 14 euros.",
                    translation: "Das kostet Sie ungefähr 14 Euro.", fromHome: false),
            Message(original: "Super, can I have that with more onions as well, please?",
                    translation: "Super, kann ich das mit mehr Zwiebeln haben, bitte?", fromHome: false),
            Message(original: "Ich hätte gerne ein großes Kölsch Bier.",
                    translation: "I'd like a large Kölsch beer.", fromHome: true),
            Message(original: "und einen Eimer voller Pommes.",
                    translation: "and a bucket full of fries.", fromHome: true),
        ]
        #endif
    }

    /// Drives the ring animations with synthetic data so they can be SEEN in
    /// the Simulator (which has no usable mic): 4s of voice-like levels,
    /// then 4s of "speaking", repeating. DEBUG only, opt-in:
    ///   xcrun simctl launch booted com.klock.heikotranslate -UITestRings YES
    private func startRingDemoIfRequested() {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "UITestRings") else { return }
        isListening = true
        hasEverStarted = true
        var tick = 0.0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                tick += 1.0 / 30.0
                let phase = tick.truncatingRemainder(dividingBy: 8)
                if phase < 4 {
                    self.activity = .understanding
                    // Voice-ish: syllable wobble on a loudness envelope.
                    let envelope = (sin(phase * 1.6) + 1) / 2
                    let syllables = (sin(phase * 11) + 1) / 2
                    self.micLevel = min(1, envelope * (0.35 + 0.65 * syllables))
                } else {
                    self.activity = .translating
                    self.micLevel = 0
                }
            }
        }
        #endif
    }

    // MARK: - Demo replay (DEBUG, for recording the case-study videos)

    #if DEBUG
    /// One spoken turn in a scripted demo conversation.
    private struct DemoTurn {
        let spoken: String
        let translation: String
        /// true → the home language was spoken (bubble lands right).
        let isHome: Bool
        /// How long the person takes to say it.
        let speaking: TimeInterval
    }

    /// Replays a conversation through the REAL UI — live partial text, the
    /// ring animations, the direction flip, the committed bubbles — with
    /// realistic timing and no network. The Simulator has no usable mic, so
    /// this is the only way to film the thing actually working.
    ///
    ///   xcrun simctl launch booted com.klock.heikotranslate -UITestDemo order
    ///
    /// Scripts: `order` (de↔en at a counter), `california` (three languages).
    private func startDemoIfRequested() {
        guard let name = UserDefaults.standard.string(forKey: "UITestDemo") else { return }
        let script: [DemoTurn]
        switch name {
        case "california":
            script = [
                DemoTurn(spoken: "Entschuldigung, wo finde ich hier den Bahnhof?",
                         translation: "Excuse me, where do I find the train station?",
                         isHome: true, speaking: 3.0),
                DemoTurn(spoken: "Two blocks down, then left at the lights.",
                         translation: "Zwei Blocks weiter, dann links an der Ampel.",
                         isHome: false, speaking: 2.6),
                DemoTurn(spoken: "Vielen Dank, das ist sehr nett!",
                         translation: "Thank you, that is very kind!",
                         isHome: true, speaking: 2.2),
            ]
        default:
            script = [
                DemoTurn(spoken: "Guten Tag, ich hätte gerne einen Kaffee.",
                         translation: "Good afternoon, I'd like a coffee.",
                         isHome: true, speaking: 2.8),
                DemoTurn(spoken: "Sure. For here or to go?",
                         translation: "Gerne. Zum Hiertrinken oder zum Mitnehmen?",
                         isHome: false, speaking: 2.0),
                DemoTurn(spoken: "Zum Mitnehmen, bitte. Was kostet das?",
                         translation: "To go, please. What does that cost?",
                         isHome: true, speaking: 2.6),
                DemoTurn(spoken: "Three fifty. Cash or card is fine.",
                         translation: "Drei fünfzig. Bar oder Karte, beides geht.",
                         isHome: false, speaking: 2.4),
            ]
        }

        isListening = true
        hasEverStarted = true
        messages = []
        Task { @MainActor in
            // Settle on the resting screen first so the loop has a clean seam.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            for turn in script {
                await self.playDemoTurn(turn)
            }
            self.activity = .idle
            self.micLevel = 0
        }
    }

    private func playDemoTurn(_ turn: DemoTurn) async {
        liveIsHome = turn.isHome
        activity = .understanding
        let words = turn.spoken.split(separator: " ").map(String.init)
        let perWord = turn.speaking / Double(max(1, words.count))
        var shown: [String] = []
        for word in words {
            shown.append(word)
            liveTranscript = shown.joined(separator: " ")
            // Voice-like level so the listening rings breathe with the speech.
            let steps = max(1, Int(perWord / 0.04))
            for i in 0..<steps {
                let t = Double(i) / Double(steps)
                micLevel = min(1, 0.30 + 0.70 * abs(sin(t * .pi)) * Double.random(in: 0.6...1.0))
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        micLevel = 0
        // The speaker stops; the translation is spoken back.
        try? await Task.sleep(nanoseconds: 500_000_000)
        activity = .translating
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        messages.append(Message(original: turn.spoken,
                                translation: turn.translation,
                                fromHome: turn.isHome))
        liveTranscript = ""
        liveIsHome = nil
        activity = .idle
        try? await Task.sleep(nanoseconds: 700_000_000)
    }
    #endif

    init() {
        // Remote-support hatch. Picking German on the PARTNER wheel swaps the
        // sides, which is the correct gesture in general but leaves this app
        // showing English as the large line — wrong for the one person it is
        // for, and not obvious to undo if you do not read English. Launch with
        //   xcrun devicectl device process launch --device <id> \
        //     com.klock.heikotranslate -ResetLanguagePair YES
        // to put German back on the home side.
        let resetPair = UserDefaults.standard.bool(forKey: "ResetLanguagePair")
        homeLang = resetPair ? Self.defaultHomeLang
                             : Self.loadLang("settings.homeLang", default: Self.defaultHomeLang)
        partnerLang = resetPair ? Self.defaultPartnerLang
                                : Self.loadLang("settings.partnerLang", default: Self.defaultPartnerLang)
        // The #30 belt in homeLang's didSet cannot cover this path — property
        // observers do not fire during init — and a stored value is the one
        // way a partner-only home can actually arrive (a future migration, a
        // hand-edited container; no shipped build writes one). Normalize it
        // BEFORE the distinct-pair fix below, so the fallback goes through
        // the same collision repair as any loaded pair. GitHub #90.
        let storedHomeWasPartnerOnly = !homeLang.canBeHome
        if storedHomeWasPartnerOnly {
            diag("app", "stored home \(homeLang.rawValue) is partner-only — repaired to \(Self.defaultHomeLang.rawValue)")
            homeLang = Self.defaultHomeLang
        }
        if homeLang == partnerLang { partnerLang = homeLang == .en ? .de : .en }
        if resetPair || storedHomeWasPartnerOnly {
            // Property observers do not fire during init, so write it through
            // by hand — otherwise the reset (or the repair) lasts only for
            // this launch.
            UserDefaults.standard.set(homeLang.rawValue, forKey: "settings.homeLang")
            UserDefaults.standard.set(partnerLang.rawValue, forKey: "settings.partnerLang")
            if resetPair {
                diag("app", "language pair RESET to \(homeLang.rawValue)↔\(partnerLang.rawValue)")
            }
        }
        seedSampleConversationIfRequested()
        startRingDemoIfRequested()
        #if DEBUG
        startDemoIfRequested()
        #endif
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleAudioInterruption(note) }
        }
    }

    private func start() {
        serviceStartCount += 1
        #if DEBUG
        // Test seam (GitHub #13): the counting above is the real path's; a
        // stub stands in only for the audio-and-network step below it.
        if let stub = serviceStartForTesting {
            isListening = stub()
            return
        }
        #endif
        errorMessage = nil
        // A fresh start re-judges the connection — never resurrect a warning
        // frozen at mute time (nothing publishes quality while muted), or
        // "Keine Internetverbindung." sits over "Verbinde…" on a healthy
        // network. The service resets its quality state to match.
        connectionWarning = nil
        do {
            try translator.start(
                home: homeLang,
                partner: partnerLang,
                onPartialInput: { [weak self] text in
                    self?.liveTranscript = text
                },
                onUtterance: { [weak self] original, translation, wasHome in
                    guard let self, !original.isEmpty else { return }
                    self.messages.append(Message(original: original, translation: translation, fromHome: wasHome))
                    self.liveTranscript = ""
                    // Translation is flowing, so the connection evidently
                    // works — don't leave a stale error banner up. Unless
                    // the key was revoked mid-conversation: a straggler
                    // utterance landing after that verdict must not wipe
                    // the one sentence that says what to do. GitHub #9.
                    if !self.keyRevoked { self.errorMessage = nil }
                },
                onActivity: { [weak self] activity in
                    self?.activity = activity
                },
                onError: { [weak self] message in
                    self?.handleServiceError(message)
                },
                onInputLevel: { [weak self] level in
                    // Smooth the jitter out, but let a rise through fast so
                    // the flag moves the moment someone starts talking.
                    guard let self else { return }
                    self.micLevel = level > self.micLevel
                        ? level
                        : self.micLevel * 0.8 + level * 0.2
                },
                onDirection: { [weak self] isHome in
                    self?.liveIsHome = isHome
                },
                onServerRecovered: { [weak self] in
                    self?.errorMessage = nil
                },
                onSessionsExhausted: { [weak self] in
                    // Both sides failed for good. Drop to the muted state so
                    // the button reads "Mikrofon pausiert" and tapping it is
                    // the obvious next move — the existing error line already
                    // says "bitte nochmal versuchen". Leaving the spinner up
                    // beside that error was two contradictory claims at once.
                    // GitHub #4, SPEC R8.
                    self?.handleSessionsExhausted()
                },
                onMicUnrecoverable: { [weak self] in
                    self?.handleMicUnrecoverable()
                },
                onConnectionQuality: { [weak self] quality in
                    guard let self else { return }
                    self.connectionWarning = Self.warning(for: quality, in: self.homeLang)
                }
            )
            isListening = true
        } catch {
            diag("app", "start FAILED: \(error.localizedDescription)")
            errorMessage = strings.micFailed
        }
    }

    private func stop() {
        // A stop of any kind voids a start still in flight — a stale grant
        // must not arrive afterwards and restart what was just stopped.
        // GitHub #13.
        invalidatePendingStart()
        translator.stopSession()
        // The notice describes a listening state that is now over — it must
        // never linger over "Mikrofon pausiert". GitHub #28.
        clearMicNotice()
        isListening = false
        activity = .idle
        liveTranscript = ""
        liveIsHome = nil
        micLevel = 0
    }
}
