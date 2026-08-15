import Foundation

/// The session's lifecycle as ONE pure value: the flags the class used to
/// keep as loose `Bool`s — written on the main thread by `close()`, written
/// and read on URLSession's private delegate queue by the callbacks, with no
/// synchronization between them (GitHub #1) — plus the exactly-once failure
/// latch, with the decisions that read them as mutating functions.
///
/// Pure so L1 can drive the interleavings: an intentional close racing
/// `didCompleteWithError` used to be able to misclassify our own close as
/// server-initiated and trigger a reconnect nobody asked for, and a single
/// pre-handshake failure reported `.error` from up to three sites, burning
/// the orchestrator's whole retry budget on one transient refusal. The class
/// guards one instance of this with a lock; the decisions live here.
struct SessionLifecycle {
    /// True once the WebSocket handshake succeeded. After this point, a
    /// transport failure or close is a normal session end, NOT a connection
    /// error the user should see.
    var hasOpened = false
    /// True once we've asked to close, or the server has closed / sent
    /// goAway. Suppresses the flurry of follow-on send/receive failures a
    /// closing socket produces.
    var isClosing = false
    /// True only when the orchestrator explicitly closed this session
    /// (mute / stop) — an intentional close must never look server-initiated.
    var intentionalClose = false
    /// The server announced the end with `goAway`, so the close that follows
    /// is planned rather than a network drop. GitHub #3.
    var sawGoAway = false
    /// The reason text of a server-initiated close, kept so the completion
    /// callback can tell an authentication rejection (capped retries, key
    /// probe) from a network drop (reconnect forever). A dead key closes
    /// AFTER a successful handshake — learned on the device, GitHub #9.
    var closeReason: String?
    /// The exactly-once latch: a session instance reports terminal failure
    /// ONE time, however many transport callbacks observe it. GitHub #1.
    private(set) var didReportFailure = false

    /// Intent counts by itself: a user-requested close is expected from the
    /// moment it is intended, not from the moment the transport is marked
    /// closing. The first cut checked only `isClosing || hasOpened`, and a
    /// pre-handshake failure landing between "intent recorded" and
    /// "transport marked closing" claimed the failure latch for a stop the
    /// user asked for (#59 review). The class also sets both under ONE lock
    /// acquisition now — this is the belt to that buckle.
    var closeIsExpected: Bool { isClosing || hasOpened || intentionalClose }

    /// Claim the right to report a terminal failure. True exactly once.
    mutating func claimFailure() -> Bool {
        guard !didReportFailure else { return false }
        didReportFailure = true
        return true
    }

    enum TransportFailureDisposition: Equatable {
        /// The socket is closing or the session ran — expected noise.
        case ignoredAfterClose
        /// The first observer of a real pre-handshake failure: report it.
        case reportOnce
        /// Another site already reported this session's failure: log only.
        case suppressedDuplicate
    }

    /// A send or receive callback failed.
    mutating func noteTransportFailure() -> TransportFailureDisposition {
        if closeIsExpected { return .ignoredAfterClose }
        return claimFailure() ? .reportOnce : .suppressedDuplicate
    }

    enum CompletionDisposition: Equatable {
        /// We closed on purpose — nothing to report.
        case quiet
        /// The server ended a session that had opened — reconnect (R7);
        /// `expected` says whether goAway announced it first.
        case closed(expected: Bool)
        /// Never opened, and this is the first report: a real connect/auth
        /// failure worth surfacing.
        case failure
        /// Opened, then closed by the server with an AUTH rejection — a dead
        /// key completes the handshake first (device-verified, GitHub #9).
        /// Must take the capped-retry path, never reconnect-forever.
        case authRejected(String)
    }

    /// The URLSession task completed (the final word on any transport).
    mutating func noteTaskCompleted() -> CompletionDisposition {
        guard !intentionalClose else { return .quiet }
        if hasOpened {
            if !sawGoAway, let reason = closeReason,
               KeyCheck.suspectsAuth(closeReason: reason) {
                return .authRejected(reason)
            }
            return .closed(expected: sawGoAway)
        }
        return claimFailure() ? .failure : .quiet
    }
}

/// One WebSocket connection to the Gemini Live Translate API
/// (`gemini-3.5-live-translate-preview`), fixed to a single target
/// language with automatic source-language detection. Three of these run
/// concurrently in `GeminiLiveTranslationService` (targets "de", "en" and
/// "es") to reproduce the app's asymmetric translation rules, because the
/// API itself only supports one fixed target per session.
///
/// The wire format below was verified against the live API directly (a
/// standalone script, outside the app) on 2026-07-19: setup, streaming
/// audio in, and receiving transcripts + translated audio back all
/// confirmed working. One documented shape was wrong and got fixed —
/// `inputAudioTranscription`/`outputAudioTranscription` must be siblings
/// of `generationConfig`, not nested inside it.
///
/// Also confirmed: this preview model does **not** reliably send
/// `serverContent.turnComplete`, even minutes into a normal response —
/// contrary to the general Live API docs. `GeminiLiveTranslationService`
/// ignores it entirely and resolves turns by idle-timeout; it is still
/// parsed and surfaced as an event in case a future orchestrator wants it.
/// Every unrecognized server message is surfaced via `.raw(...)` instead
/// of being silently dropped, so any further mismatch is visible in logs.
final class GeminiLiveSession: NSObject {
    enum Event {
        case setupComplete
        /// WebSocket handshake succeeded — the socket can carry audio now.
        case opened
        /// Raw 16-bit PCM, 24kHz, mono, little-endian.
        case audioChunk(Data)
        /// Detected language of the user's speech (BCP-47), streamed as a
        /// preamble. Lets the orchestrator tell the translating session from
        /// the echoing one.
        case inputLanguage(String)
        /// Language of this session's spoken output (BCP-47).
        case outputLanguage(String)
        case inputTranscript(String)
        case outputTranscript(String)
        case turnComplete
        /// The server abandoned the response it was streaming: the audio
        /// chunks sent for it are superseded, and a replacement follows.
        ///
        /// Recognised but ignored until 2026-08-14 — which is exactly why
        /// #112 exists. Every chunk of an abandoned rendering stays in
        /// `pendingOutput` and is played at commit, so the listener hears a
        /// false start and then the correction. Surfaced now to establish
        /// whether this preview model sends the signal at all; its
        /// neighbours `turnComplete` and `generationComplete` are documented
        /// above as unreliable on this model, and nothing can be built on it
        /// until that is known.
        case interrupted
        /// Token accounting for this session, as sent by the server.
        case usage([String: Any])
        case raw(String)
        case error(String)
        /// The session ended on its own. Not a user error — the orchestrator
        /// should reconnect to keep going.
        ///
        /// `expected` is true only when the server announced it first with
        /// `goAway` (Live sessions have a bounded duration). False means the
        /// transport dropped abruptly after a successful handshake — a
        /// flapping network rather than a planned end. The two deserve
        /// different reconnect urgency, and reporting both identically let a
        /// flapping connection reconnect with no cooldown at all. GitHub #3.
        case closed(expected: Bool)
        /// Non-error diagnostic detail (HTTP status, close code, etc.) —
        /// separate from `.error` so it's easy to filter in logs.
        case debug(String)
    }

    private static let endpoint = URL(
        string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    )!

    private let targetLanguageCode: String
    private let apiKey: String
    private let onEvent: (Event) -> Void

    private var urlSession: URLSession!

    /// The lifecycle flags and the task reference, guarded by one lock.
    /// `close()` runs on the main thread; the URLSession callbacks and the
    /// send/receive completions run on the session's private delegate queue;
    /// the old loose properties were shared between them with nothing making
    /// the writes visible or the read-modify-writes atomic. Every access now
    /// goes through `withLifecycle` / the task accessors below. GitHub #1.
    private let stateLock = NSLock()
    private var lifecycle = SessionLifecycle()
    private var task: URLSessionWebSocketTask?

    private func withLifecycle<T>(_ body: (inout SessionLifecycle) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&lifecycle)
    }

    private func currentTask() -> URLSessionWebSocketTask? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return task
    }

    private func storeTask(_ new: URLSessionWebSocketTask?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        task = new
    }

    init(targetLanguageCode: String, apiKey: String, onEvent: @escaping (Event) -> Void) {
        self.targetLanguageCode = targetLanguageCode
        self.apiKey = apiKey
        self.onEvent = onEvent
        super.init()
        // A delegate-backed session (rather than the default shared-style
        // session) is what lets us see *why* a connection died — HTTP
        // status from a rejected handshake, or a proper WebSocket close
        // code — instead of just a generic "socket not connected" error.
        self.urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func connect() {
        diag("session", "[\(targetLanguageCode)] connecting")
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        let task = urlSession.webSocketTask(with: components.url!)
        storeTask(task)
        task.resume()
        receiveLoop(task)
        sendSetup()
    }

    /// Orchestrator-requested close (mute / stop). Marks the close as
    /// intentional so no reconnect is attempted — and does so under the lock
    /// BEFORE touching the transport, so the completion callback can never
    /// observe the teardown without the intent (the misclassification race
    /// in GitHub #1: our own close read as server-initiated, triggering a
    /// reconnect nobody asked for).
    func close() {
        beginTeardown(intentional: true)
        // A URLSession strongly retains its delegate until invalidated, and
        // this class IS its URLSession's delegate — so without this line every
        // GeminiLiveSession ever constructed was immortal, along with whatever
        // transport state it still held. With goAway ending sessions every ~9
        // minutes, an afternoon of use leaked dozens of them. GitHub #19.
        // (invalidateAndCancel fires one final didCompleteWithError; the
        // intentionalClose flag above keeps that path quiet.)
        urlSession.invalidateAndCancel()
    }

    /// Close our side WITHOUT marking it intentional — used for goAway, so
    /// `didCompleteWithError` still emits `.closed` and the orchestrator
    /// reconnects (SPEC R7). Marking goAway closes as intentional was a real
    /// bug: the session died permanently after its bounded duration.
    private func closeTransport() {
        beginTeardown(intentional: false)
    }

    /// One atomic step: record WHY the transport is going away, mark it
    /// closing, and take ownership of the task — under a single lock
    /// acquisition. close() used to record intent and mark closing in two
    /// separate acquisitions, and a failure callback landing in the gap saw
    /// intent without the closing state, claiming the failure latch for a
    /// stop the user asked for (#59 review). No callback can observe a
    /// half-recorded close now.
    private func beginTeardown(intentional: Bool) {
        stateLock.lock()
        if intentional { lifecycle.intentionalClose = true }
        lifecycle.isClosing = true
        let closing = task
        task = nil
        stateLock.unlock()
        closing?.cancel(with: .goingAway, reason: nil)
    }

    /// Streams one chunk of mic audio. Must already be raw 16-bit PCM,
    /// 16kHz, mono, little-endian.
    func sendAudio(_ pcm16kData: Data) {
        send(json: [
            "realtimeInput": [
                "audio": [
                    "data": pcm16kData.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ])
    }

    // MARK: - Outgoing

    private func sendSetup() {
        send(json: [
            "setup": [
                "model": "models/gemini-3.5-live-translate-preview",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "translationConfig": [
                        "targetLanguageCode": targetLanguageCode,
                        "echoTargetLanguage": false
                    ]
                ],
                // Confirmed via a direct WebSocket protocol test (bypassing
                // the app entirely) that these must be siblings of
                // generationConfig, not nested inside it — the server
                // rejects the nested form with "Unknown name
                // 'inputAudioTranscription' at 'setup.generation_config'".
                "inputAudioTranscription": [String: Any](),
                "outputAudioTranscription": [String: Any]()
            ]
        ])
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8)
        else { return }
        currentTask()?.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            self.reportTransportFailure("send", error)
        }
    }

    /// One reporting point for send and receive failures, behind the
    /// exactly-once latch: a single dead socket fails every in-flight send
    /// AND the receive loop, and each used to emit its own `.error` — the
    /// orchestrator counted every one against its 3-attempt retry budget, so
    /// one transient refusal could burn the lot instantly. GitHub #1.
    private func reportTransportFailure(_ side: String, _ error: Error) {
        switch withLifecycle({ $0.noteTransportFailure() }) {
        case .ignoredAfterClose:
            onEvent(.debug("\(side) ended after close (ignored): \(error.localizedDescription)"))
        case .reportOnce:
            onEvent(.error("\(side) failed: \(error.localizedDescription)"))
        case .suppressedDuplicate:
            onEvent(.debug("\(side) failed after the failure was already reported: \(error.localizedDescription)"))
        }
    }

    // MARK: - Incoming

    /// The loop holds the task it was armed for, rather than re-reading a
    /// property another thread may have swapped or cleared mid-loop.
    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.reportTransportFailure("receive", error)
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleServerMessage(text)
                case .data(let data):
                    self.handleServerMessage(String(data: data, encoding: .utf8) ?? "")
                @unknown default:
                    break
                }
                self.receiveLoop(task)
            }
        }
    }

    /// serverContent sub-keys we understand. Anything outside this set is
    /// worth surfacing via `.raw` (it might be the audio in an unexpected
    /// shape). Keys inside it that we simply don't act on — like the
    /// `languageCode`-only transcription preambles the model streams before
    /// real text, or `interrupted` — are known-benign and stay quiet.
    private static let knownServerContentKeys: Set<String> = [
        "modelTurn", "inputTranscription", "outputTranscription",
        "turnComplete", "generationComplete", "interrupted"
    ]

    #if DEBUG
    /// Drive the real server-message parser from a test, without a socket.
    /// The parser is where `interrupted` is either recognised or lost, and
    /// a frame that is silently swallowed looks exactly like a model that
    /// never sent one — which is the confusion #112 was stuck in. Same
    /// method the socket calls. Excluded from the swiftc harnesses, which
    /// do not define DEBUG.
    func handleServerMessageForTesting(_ text: String) { handleServerMessage(text) }
    #endif

    private func handleServerMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            onEvent(.raw(text))
            return
        }

        if object["setupComplete"] != nil {
            diag("session", "[\(targetLanguageCode)] setupComplete")
            onEvent(.setupComplete)
            return
        }

        if let errorObject = object["error"] {
            diag("session", "[\(targetLanguageCode)] server error: \(errorObject)")
            onEvent(.error("\(errorObject)"))
            return
        }

        // Token accounting, streamed continuously while a session is open.
        if let usage = object["usageMetadata"] as? [String: Any] {
            onEvent(.usage(usage))
            return
        }
        // Benign keepalive frames, acknowledged and ignored so they don't
        // bury the real content in "unrecognized message" spam.
        if object["sessionResumptionUpdate"] != nil {
            return
        }
        if object["goAway"] != nil {
            // The server is about to close this session (Live sessions have a
            // bounded duration). It expects us to close promptly — if we
            // don't, it force-closes with a 1008 policy-violation code. So
            // close our side now; the resulting transport failures are then
            // treated as expected (closeIsExpected) and stay quiet.
            diag("session", "[\(targetLanguageCode)] goAway — closing our side")
            onEvent(.debug("server goAway (closing our side): \(text)"))
            withLifecycle { $0.sawGoAway = true }
            closeTransport()
            return
        }

        guard let serverContent = object["serverContent"] as? [String: Any] else {
            onEvent(.raw(text))
            return
        }

        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let inlineData = part["inlineData"] as? [String: Any],
                   let base64 = inlineData["data"] as? String,
                   let audio = Data(base64Encoded: base64) {
                    onEvent(.audioChunk(audio))
                }
            }
        }

        if let inputTranscription = serverContent["inputTranscription"] as? [String: Any] {
            // The model streams the detected input language as a preamble
            // (before/without text). It's what tells us which of the two
            // sessions is doing a real translation vs echoing the source.
            if let lang = inputTranscription["languageCode"] as? String {
                onEvent(.inputLanguage(lang))
            }
            if let text = inputTranscription["text"] as? String, !text.isEmpty {
                onEvent(.inputTranscript(text))
            }
        }

        if let outputTranscription = serverContent["outputTranscription"] as? [String: Any] {
            if let lang = outputTranscription["languageCode"] as? String {
                onEvent(.outputLanguage(lang))
            }
            if let text = outputTranscription["text"] as? String, !text.isEmpty {
                onEvent(.outputTranscript(text))
            }
        }

        // Both are end-of-response signals in the Live API. This preview
        // model doesn't reliably send either, so the orchestrator ignores
        // the event and resolves turns by idle timeout; it's still surfaced
        // here for logging and future use.
        if (serverContent["turnComplete"] as? Bool) == true
            || (serverContent["generationComplete"] as? Bool) == true {
            onEvent(.turnComplete)
        }

        // The response being streamed was abandoned; what follows replaces
        // it. Surfaced so the orchestrator can drop the superseded audio it
        // is holding (#112) — but first, so the log can answer whether this
        // model sends the signal at all. It sits in `knownServerContentKeys`
        // and has therefore been arriving silently all along.
        if (serverContent["interrupted"] as? Bool) == true {
            onEvent(.interrupted)
        }

        // Surface only genuinely unfamiliar serverContent shapes — an empty
        // frame or a languageCode-only preamble is normal and stays quiet.
        let unknownKeys = Set(serverContent.keys).subtracting(Self.knownServerContentKeys)
        if !unknownKeys.isEmpty {
            diag("session", "[\(targetLanguageCode)] unrecognized keys \(unknownKeys.sorted()): \(text.prefix(300))")
            onEvent(.raw(text))
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension GeminiLiveSession: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        withLifecycle { $0.hasOpened = true }
        diag("session", "[\(targetLanguageCode)] websocket open")
        onEvent(.opened)
        onEvent(.debug("WebSocket handshake succeeded (protocol: \(`protocol` ?? "none"))"))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "(no reason given)"
        withLifecycle {
            $0.isClosing = true
            $0.closeReason = reasonText
        }
        onEvent(.debug("WebSocket closed by server. closeCode=\(closeCode.rawValue) reason=\(reasonText)"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var detail = "URLSession task completed."
        if let httpResponse = task.response as? HTTPURLResponse {
            detail += " HTTP status: \(httpResponse.statusCode)."
            if !httpResponse.allHeaderFields.isEmpty {
                detail += " Headers: \(httpResponse.allHeaderFields)."
            }
        }
        if let error {
            let nsError = error as NSError
            detail += " Error: \(nsError.domain) code=\(nsError.code) — \(nsError.localizedDescription)."
        }
        onEvent(.debug(detail))

        // A close we didn't ask for, on a session that had connected, means
        // the server ended it (duration limit / goAway). Ask to reconnect.
        // A failure before the socket ever opened is a real connection/auth
        // problem — surfaced once, however many callbacks observed it.
        switch withLifecycle({ $0.noteTaskCompleted() }) {
        case .quiet:
            break
        case .closed(let planned):
            diag("session", "[\(targetLanguageCode)] closed by server (\(planned ? "goAway" : "abrupt drop")) — will reconnect")
            onEvent(.closed(expected: planned))
        case .authRejected(let reason):
            // NOT the reconnect-forever drop path: from the transport's seat
            // an auth rejection is indistinguishable from a tunnel — except
            // by the reason text, which SessionLifecycle has already read.
            // The error event puts it on the CAPPED retry path, whose
            // exhaustion runs the key probe; the probe stays the arbiter, so
            // a one-off server hiccup still ends as "try again", not
            // "update the app". Learned on the device, GitHub #9.
            diag("session", "[\(targetLanguageCode)] closed by server with an auth rejection — session error, not a drop")
            onEvent(.error("authentication rejected on close: \(reason)"))
        case .failure:
            diag("session", "[\(targetLanguageCode)] FAILED before handshake: \(detail)")
            onEvent(.error("connection failed before handshake"))
        }
        // The task is finished either way, so the URLSession has done its job.
        // Self-invalidate here as the belt to close()'s braces: a session torn
        // down by the SERVER (goAway, abrupt drop) may sit in the orchestrator's
        // map for a while before reconnect() replaces-and-closes it, and until
        // then the retain cycle would hold. Invalidating twice is a no-op, so
        // both paths can safely do it. GitHub #19.
        session.finishTasksAndInvalidate()
    }
}
