import Foundation

/// The slice of a live session the orchestrator drives. Exists so the
/// replacement-window rules (GitHub #15) can run against a fake at L1 — for
/// the same reason `TurnLogic` is pure: the real thing needs a network. Every
/// engine's session conforms.
protocol LiveTranslationSocket: AnyObject {
    func connect()
    func close()
    func sendAudio(_ pcm16kData: Data)
}

extension GeminiLiveSession: LiveTranslationSocket {}

/// What one frame from the server asks the transport to do.
enum DialectOutput {
    /// Hand this to the orchestrator.
    case event(GeminiLiveSession.Event)
    /// Send this JSON back to the server (Grok's history pruning).
    case send([String: Any])
    /// The server said so itself: fatal before the session is ready, a
    /// diagnostic after it. The OpenAI-style protocols report a rejected
    /// client event as `error` and carry on, so treating every one as a dead
    /// session would reconnect a working socket over a bad delete.
    case serverError(String)
    /// The server announced the end of this session (a duration limit).
    /// Handled like Gemini's `goAway`: close our side, report an expected
    /// close, reconnect at once (R7).
    case serverEnding
}

/// One vendor's wire protocol, for vendors that speak the OpenAI Realtime
/// family of events. Everything transport-shaped — the socket, the lifecycle
/// latch, the heartbeat — lives in `RealtimeSocketSession` once.
///
/// Threading: `audioMessage` is called from the sending side and `parse`
/// from the socket's delegate queue. A dialect keeps the state each needs on
/// its own side (the resampler on one, the language witness on the other)
/// and shares none between them.
protocol RealtimeDialect: AnyObject {
    /// Log prefix, e.g. `openai/de`.
    var label: String { get }
    func request(apiKey: String) -> URLRequest
    func setupMessages() -> [[String: Any]]
    func audioMessage(_ pcm16k: Data) -> [String: Any]
    /// True for the frame that acknowledges setup — the moment the session
    /// can hear. The mic opens on it (see `openMicIfReady`).
    func isSetupAcknowledgement(_ type: String) -> Bool
    func parse(_ type: String, _ object: [String: Any]) -> [DialectOutput]
}

/// A WebSocket session for the OpenAI-Realtime-family engines (OpenAI,
/// Grok). The lifecycle rules are `GeminiLiveSession`'s, reused through
/// `SessionLifecycle`, because every one of them was learned from a device
/// log and none is specific to Google: one failure report per dead socket
/// (#1), goAway reconnects and our own close does not (#1, R7), the
/// URLSession released on close (#19), an auth rejection kept off the
/// reconnect-forever path (#9).
///
/// One addition: a **heartbeat**. Gemini streams usage frames the whole time
/// a session is open, and the connection-quality banner reads that stream
/// as "the server is alive". These protocols go quiet between utterances, so
/// without something in its place Heiko would see "Keine Antwort vom Server"
/// every time a conversation paused. A WebSocket ping answered by a pong is
/// the honest substitute: it proves the same round trip the banner is
/// asking about.
final class RealtimeSocketSession: NSObject, LiveTranslationSocket {

    static let heartbeatInterval: TimeInterval = 2

    private let dialect: RealtimeDialect
    private let apiKey: String
    private let onEvent: (GeminiLiveSession.Event) -> Void

    private var urlSession: URLSession!
    private let stateLock = NSLock()
    private var lifecycle = SessionLifecycle()
    private var task: URLSessionWebSocketTask?
    private var isReady = false
    private var heartbeat: DispatchSourceTimer?

    init(dialect: RealtimeDialect, apiKey: String, onEvent: @escaping (GeminiLiveSession.Event) -> Void) {
        self.dialect = dialect
        self.apiKey = apiKey
        self.onEvent = onEvent
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    func connect() {
        diag("session", "[\(dialect.label)] connecting")
        // A missing key is a setup fault, not a network one — say which
        // entry is missing instead of letting a 401 say it less clearly.
        guard !apiKey.isEmpty else {
            onEvent(.error("no API key for \(dialect.label) in Secrets.plist"))
            return
        }
        let task = urlSession.webSocketTask(with: dialect.request(apiKey: apiKey))
        withState { self.task = task }
        task.resume()
        receiveLoop(task)
        for message in dialect.setupMessages() { send(json: message) }
    }

    func close() {
        beginTeardown(intentional: true)
        urlSession.invalidateAndCancel()
    }

    func sendAudio(_ pcm16kData: Data) {
        send(json: dialect.audioMessage(pcm16kData))
    }

    private func beginTeardown(intentional: Bool) {
        stateLock.lock()
        if intentional { lifecycle.intentionalClose = true }
        lifecycle.isClosing = true
        let closing = task
        task = nil
        let beat = heartbeat
        heartbeat = nil
        stateLock.unlock()
        beat?.cancel()
        closing?.cancel(with: .goingAway, reason: nil)
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8),
              let task = withState({ self.task })
        else { return }
        task.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            self.reportTransportFailure("send", error)
        }
    }

    private func reportTransportFailure(_ side: String, _ error: Error) {
        switch withState({ lifecycle.noteTransportFailure() }) {
        case .ignoredAfterClose:
            onEvent(.debug("\(side) ended after close (ignored): \(error.localizedDescription)"))
        case .reportOnce:
            onEvent(.error("\(side) failed: \(error.localizedDescription)"))
        case .suppressedDuplicate:
            onEvent(.debug("\(side) failed after the failure was already reported: \(error.localizedDescription)"))
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let task = self.withState({ self.task }) else { return }
            task.sendPing { [weak self] error in
                if error == nil { self?.onEvent(.heartbeat) }
            }
        }
        withState { heartbeat = timer }
        timer.resume()
    }

    // MARK: - Incoming

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.reportTransportFailure("receive", error)
            case .success(let message):
                switch message {
                case .string(let text): self.handleServerMessage(text)
                case .data(let data): self.handleServerMessage(String(data: data, encoding: .utf8) ?? "")
                @unknown default: break
                }
                self.receiveLoop(task)
            }
        }
    }

    #if DEBUG
    func handleServerMessageForTesting(_ text: String) { handleServerMessage(text) }
    #endif

    private func handleServerMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            onEvent(.raw(text))
            return
        }
        if dialect.isSetupAcknowledgement(type) {
            let first = withState { () -> Bool in
                defer { isReady = true }
                return !isReady
            }
            // A later session.updated (the server echoing a change) must not
            // re-announce readiness; the orchestrator counts the first one.
            if first {
                diag("session", "[\(dialect.label)] ready (\(type))")
                startHeartbeat()
                onEvent(.setupComplete)
            }
            return
        }
        for output in dialect.parse(type, object) {
            switch output {
            case .event(let event):
                onEvent(event)
            case .send(let json):
                send(json: json)
            case .serverError(let message):
                if withState({ isReady }) {
                    diag("session", "[\(dialect.label)] server error (session continues): \(message)")
                    onEvent(.debug("server error: \(message)"))
                } else {
                    diag("session", "[\(dialect.label)] server error before ready: \(message)")
                    onEvent(.error(message))
                }
            case .serverEnding:
                diag("session", "[\(dialect.label)] server ending the session — closing our side")
                withState { lifecycle.sawGoAway = true }
                beginTeardown(intentional: false)
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RealtimeSocketSession: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        withState { lifecycle.hasOpened = true }
        diag("session", "[\(dialect.label)] websocket open")
        onEvent(.opened)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "(no reason given)"
        withState {
            lifecycle.isClosing = true
            lifecycle.closeReason = reasonText
        }
        onEvent(.debug("WebSocket closed by server. closeCode=\(closeCode.rawValue) reason=\(reasonText)"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var detail = "URLSession task completed."
        if let http = task.response as? HTTPURLResponse { detail += " HTTP status: \(http.statusCode)." }
        if let error {
            let nsError = error as NSError
            detail += " Error: \(nsError.domain) code=\(nsError.code) — \(nsError.localizedDescription)."
        }
        onEvent(.debug(detail))
        let beat = withState { () -> DispatchSourceTimer? in
            defer { heartbeat = nil }
            return heartbeat
        }
        beat?.cancel()
        switch withState({ lifecycle.noteTaskCompleted() }) {
        case .quiet:
            break
        case .closed(let planned):
            diag("session", "[\(dialect.label)] closed by server (\(planned ? "announced" : "abrupt drop")) — will reconnect")
            onEvent(.closed(expected: planned))
        case .authRejected(let reason):
            diag("session", "[\(dialect.label)] closed with an auth rejection — session error, not a drop")
            onEvent(.error("authentication rejected on close: \(reason)"))
        case .failure:
            diag("session", "[\(dialect.label)] FAILED before handshake: \(detail)")
            onEvent(.error("connection failed before handshake (\(detail))"))
        }
        session.finishTasksAndInvalidate()
    }
}
