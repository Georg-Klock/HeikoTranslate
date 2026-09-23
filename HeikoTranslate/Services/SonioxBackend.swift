import Foundation

/// Soniox as an interpreter backend: one speech-to-text stream that
/// transcribes AND translates both directions of the pair, and one
/// text-to-speech connection that speaks the translations.
///
/// Why it is shaped differently from every other engine:
///
/// - **The language is labelled, not inferred.** With `translation.type:
///   two_way`, every token comes back tagged `original` or `translation`, with
///   its `language`. The original tokens' language is the speaker's, cast as
///   the vote; the translation tokens' language is the side they belong to.
///   No session guesses who spoke from what it produced (#125, #177, #179).
/// - **Text first, then a voice.** Translation text streams in while the
///   person is still speaking. Each utterance's translation opens a TTS
///   stream in its language on the second connection, whose audio goes to
///   that language's side. The voice is Soniox's own, not a rendering of the
///   speaker's.
/// - **Transcripts use final tokens only.** Soniox also streams non-final
///   tokens, which it revises. The service APPENDS every transcript it
///   receives and cannot un-append a revision, so only finals are passed on.
///
/// Wire shapes are from Soniox's documentation (2026-09): STT at
/// `stt-rt.soniox.com/transcribe-websocket` (config JSON first, then binary
/// PCM), TTS at `tts-rt.soniox.com/tts-websocket` (streams multiplexed by
/// `stream_id`, base64 audio back).
final class SonioxBackend: NSObject, InterpreterBackend {

    static let sttURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    static let ttsURL = URL(string: "wss://tts-rt.soniox.com/tts-websocket")!
    static let sttModel = "stt-rt-v5"
    static let ttsModel = "tts-rt-v2"
    /// Soniox voices are multilingual: one voice speaks every language of
    /// the pair with the same timbre.
    static let voice = "Adrian"
    /// Soniox closes an idle connection after 20-30s. The silence gate stops
    /// sending audio while nobody talks, so both connections need a keepalive.
    static let keepaliveInterval: TimeInterval = 10
    static let heartbeatInterval: TimeInterval = 2

    private let pair: [String]
    private let apiKey: String
    private let sink: InterpreterEventSink

    private var urlSession: URLSession!
    private let lock = NSLock()
    private var stt: URLSessionWebSocketTask?
    private var tts: URLSessionWebSocketTask?
    private var closing = false
    private var reportedEnd = false
    private var opened = false
    private var timer: DispatchSourceTimer?
    private var lastKeepalive = Date.distantPast

    /// Receive side (the delegate queue) only.
    private var parser: SonioxTokenParser

    init(pair: [String], apiKey: String, sink: @escaping InterpreterEventSink) {
        self.pair = pair
        self.apiKey = apiKey
        self.sink = sink
        self.parser = SonioxTokenParser(pair: pair)
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: InterpreterBackend

    func connect() {
        let label = "soniox/\(pair.joined(separator: "+"))"
        diag("session", "[\(label)] connecting")
        guard !apiKey.isEmpty else {
            sink(.error("no API key for \(label) in Secrets.plist"), nil)
            return
        }
        let stt = urlSession.webSocketTask(with: Self.sttURL)
        let tts = urlSession.webSocketTask(with: Self.ttsURL)
        locked { self.stt = stt; self.tts = tts }
        stt.resume()
        tts.resume()
        receive(stt, isSTT: true)
        receive(tts, isSTT: false)
        send(text: json(sttConfig), on: stt) { [weak self] ok in
            guard let self, ok else { return }
            // Soniox acknowledges nothing: a config it rejects comes back as
            // an error frame, which still ends the session as an error.
            diag("session", "[\(label)] ready (config sent)")
            self.startTimers()
            self.sink(.setupComplete, nil)
        }
    }

    func close() {
        let (stt, tts, timer) = locked { () -> (URLSessionWebSocketTask?, URLSessionWebSocketTask?, DispatchSourceTimer?) in
            closing = true
            defer { self.stt = nil; self.tts = nil; self.timer = nil }
            return (self.stt, self.tts, self.timer)
        }
        timer?.cancel()
        stt?.cancel(with: .goingAway, reason: nil)
        tts?.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
    }

    func sendAudio(_ pcm16kData: Data) {
        guard let stt = locked({ stt }) else { return }
        stt.send(.data(pcm16kData)) { [weak self] error in
            if let error { self?.fail("audio send failed: \(error.localizedDescription)") }
        }
    }

    // MARK: Outgoing

    private var sttConfig: [String: Any] {
        [
            "api_key": apiKey,
            "model": Self.sttModel,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "language_hints": pair,
            "enable_language_identification": true,
            "enable_endpoint_detection": true,
            "translation": ["type": "two_way", "language_a": pair[0], "language_b": pair[1]],
        ]
    }

    private func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func send(text: String, on task: URLSessionWebSocketTask?, done: ((Bool) -> Void)? = nil) {
        guard let task else { done?(false); return }
        task.send(.string(text)) { [weak self] error in
            if let error { self?.fail("send failed: \(error.localizedDescription)") }
            done?(error == nil)
        }
    }

    private func sendTTS(_ object: [String: Any]) {
        send(text: json(object), on: locked { tts })
    }

    private func startTimers() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.beat() }
        locked { self.timer = timer }
        timer.resume()
    }

    /// Every 2s a ping on the STT socket (the connection banner's liveness,
    /// as for the other engines); every 10s a keepalive on both, because the
    /// silence gate can leave them without traffic for minutes.
    private func beat() {
        let (stt, tts) = locked { (self.stt, self.tts) }
        stt?.sendPing { [weak self] error in if error == nil { self?.sink(.heartbeat, nil) } }
        guard Date().timeIntervalSince(lastKeepalive) >= Self.keepaliveInterval else { return }
        lastKeepalive = Date()
        send(text: #"{"type":"keepalive"}"#, on: stt)
        send(text: #"{"keep_alive":true}"#, on: tts)
    }

    // MARK: Incoming

    private func receive(_ task: URLSessionWebSocketTask, isSTT: Bool) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail("\(isSTT ? "stt" : "tts") receive failed: \(error.localizedDescription)")
            case .success(let message):
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: text = ""
                }
                if let data = text.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    isSTT ? self.handleSTT(object) : self.handleTTS(object)
                }
                self.receive(task, isSTT: isSTT)
            }
        }
    }

    private func handleSTT(_ object: [String: Any]) {
        if let code = object["error_code"] {
            fail("stt error \(code): \(object["error_message"] as? String ?? "")")
            return
        }
        if (object["finished"] as? Bool) == true {
            end(expected: true)
            return
        }
        let tokens = (object["tokens"] as? [[String: Any]]) ?? []
        for action in parser.consume(tokens) {
            switch action {
            case .spoken(let text, let language):
                if let language { sink(.inputLanguage(language), nil) }
                sink(.inputTranscript(text), nil)
            case .translated(let text, let language):
                sink(.outputTranscript(text), language)
            case .speak(let streamID, let text, let language, let opens):
                if opens {
                    sendTTS(["api_key": apiKey, "stream_id": streamID, "model": Self.ttsModel,
                             "language": language, "voice": Self.voice,
                             "audio_format": "pcm_s16le", "sample_rate": 24_000])
                }
                sendTTS(["stream_id": streamID, "text": text, "text_end": false])
            case .endSpeech(let streamID):
                sendTTS(["stream_id": streamID, "text": "", "text_end": true])
            case .utteranceEnded:
                sink(.turnComplete, nil)
            }
        }
    }

    private func handleTTS(_ object: [String: Any]) {
        let streamID = object["stream_id"] as? String ?? ""
        if let code = object["error_code"] {
            // One failed utterance voice must not kill the conversation: the
            // text still arrived, and the next utterance opens a new stream.
            let message = "tts stream \(streamID) error \(code): \(object["error_message"] as? String ?? "")"
            diag("session", "[soniox] \(message)")
            sink(.debug(message), nil)
            return
        }
        if let base64 = object["audio"] as? String, let audio = Data(base64Encoded: base64), !audio.isEmpty,
           let language = SonioxTokenParser.language(ofStream: streamID) {
            sink(.audioChunk(audio), language)
        }
    }

    // MARK: Ending

    /// Reported once, however many sockets and callbacks observe it.
    private func fail(_ message: String) {
        let first = locked { () -> Bool in
            guard !closing, !reportedEnd else { return false }
            reportedEnd = true
            return true
        }
        guard first else { return }
        diag("session", "[soniox] ERROR: \(message)")
        sink(.error(message), nil)
    }

    private func end(expected: Bool) {
        let first = locked { () -> Bool in
            guard !closing, !reportedEnd else { return false }
            reportedEnd = true
            return true
        }
        if first { sink(.closed(expected: expected), nil) }
    }
}

extension SonioxBackend: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let first = locked { () -> Bool in defer { opened = true }; return !opened }
        if first { sink(.opened, nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A socket ending on its own after the session was up is a drop (R7:
        // the service reconnects); before that, a failure to connect.
        if locked({ opened }) { end(expected: false) } else { fail("connection failed before handshake") }
    }
}

/// Turns Soniox's token stream into what the app needs. Pure, so the token
/// rules are pinned at L1 without a socket.
///
/// Soniox sends every final token once and non-final tokens repeatedly, as a
/// revisable tail. Only finals count here. Within finals:
/// - `original` tokens are the speaker's words (the input transcript), and
///   their `language` is the speaker's vote;
/// - `translation` tokens are the translation (the output transcript) and
///   the text to speak, in their own `language`;
/// - `<end>` closes the utterance: the voice streams it opened are ended.
struct SonioxTokenParser {

    enum Action: Equatable {
        case spoken(text: String, language: String?)
        case translated(text: String, language: String)
        /// Send `text` to TTS stream `streamID`, opening it first if `opens`.
        case speak(streamID: String, text: String, language: String, opens: Bool)
        case endSpeech(streamID: String)
        case utteranceEnded
    }

    let pair: [String]
    private var utterance = 0
    /// Voice streams opened in the current utterance, by language.
    private var openStreams: [String: String] = [:]

    init(pair: [String]) { self.pair = pair }

    /// Stream ids carry their language so audio can be routed from the id
    /// alone: `u<utterance>-<language>`.
    static func language(ofStream id: String) -> String? {
        id.split(separator: "-").last.map(String.init)
    }

    mutating func consume(_ tokens: [[String: Any]]) -> [Action] {
        var actions: [Action] = []
        var spoken = "", spokenLanguage: String?
        var translated: [String: String] = [:]
        var ended = false

        for token in tokens where (token["is_final"] as? Bool) == true {
            guard let text = token["text"] as? String else { continue }
            if text == "<end>" { ended = true; continue }
            if text.hasPrefix("<"), text.hasSuffix(">") { continue }   // other control tokens
            let language = token["language"] as? String
            switch token["translation_status"] as? String {
            case "translation":
                guard let language, pair.contains(language) else { continue }
                translated[language, default: ""] += text
            default:  // "original" or "none"
                spoken += text
                if let language, pair.contains(language) { spokenLanguage = language }
            }
        }

        if !spoken.isEmpty { actions.append(.spoken(text: spoken, language: spokenLanguage)) }
        for language in pair {
            guard let text = translated[language], !text.isEmpty else { continue }
            actions.append(.translated(text: text, language: language))
            let opens = openStreams[language] == nil
            let id = openStreams[language] ?? "u\(utterance)-\(language)"
            openStreams[language] = id
            actions.append(.speak(streamID: id, text: text, language: language, opens: opens))
        }
        if ended {
            for language in pair { if let id = openStreams[language] { actions.append(.endSpeech(streamID: id)) } }
            openStreams = [:]
            utterance += 1
            actions.append(.utteranceEnded)
        }
        return actions
    }
}
