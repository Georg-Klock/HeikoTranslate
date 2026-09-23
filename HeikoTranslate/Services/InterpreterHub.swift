import Foundation

/// One OpenAI realtime session interpreting BOTH directions of the pair,
/// presented to the service as the two sessions it expects.
///
/// The other engines run one session per side, each fixed to one output
/// language, and the turn machinery decides who spoke from which session
/// translated. Here a single `gpt-realtime-2` session is told to put German
/// into English and English into German. That halves the sessions, and with
/// it the idle input bill. The service stays unchanged: it still builds
/// one session per language, and each of those is an `InterpreterProxy` onto
/// the one shared connection.
///
/// **Who spoke is read, not asked.** The first idea was a text label ("[A]")
/// at the start of each reply. Measured 2026-09-23: the API refuses audio and
/// text output together ("Supported combinations are: ['text'] and
/// ['audio']"), and with audio only the label becomes part of what the model
/// SAYS. So the hub reads the language of what the model is saying instead:
/// the reply's transcript, classified between the pair's two languages. A
/// reply in English means German was spoken. The reply goes to the proxy for
/// its language, which is exactly the shape of the two-session engines: the
/// translating side talks, the other stays silent.
///
/// **Routing waits for the language.** A reply's first audio arrives before
/// its transcript has enough words to classify, so the hub holds the reply
/// until it knows, then flushes it to the right proxy. The service holds
/// audio until commit anyway, so the wait costs no playback time.
/// What a hub drives: one connection (or a pair of them, for Soniox) that
/// hears the whole conversation.
protocol InterpreterBackend: AnyObject {
    func connect()
    func close()
    func sendAudio(_ pcm16kData: Data)
}

extension RealtimeSocketSession: InterpreterBackend {}

/// A backend's events. `language` is set when the backend KNOWS which of the
/// pair an output event is in (Soniox labels every token); the hub then
/// routes it directly. Nil means "work it out from the reply's transcript".
typealias InterpreterEventSink = (_ event: GeminiLiveSession.Event, _ language: String?) -> Void

final class InterpreterHub {

    // MARK: Registry — one live hub per pair

    private static let registryLock = NSLock()
    private static var live: [String: InterpreterHub] = [:]

    /// `makeBackend` builds the connection the first time a pair's hub is
    /// created; the second side of the pair attaches to that hub.
    static func proxy(engine: TranslationEngine, target: String, partner: String,
                      onEvent: @escaping (GeminiLiveSession.Event) -> Void,
                      makeBackend: @escaping (_ pair: [String], _ sink: @escaping InterpreterEventSink) -> InterpreterBackend)
        -> InterpreterProxy {
        let pair = [target, partner].sorted()
        let key = engine.rawValue + "|" + pair.joined(separator: "|")
        registryLock.lock()
        let hub: InterpreterHub
        if let existing = live[key], !existing.isDead {
            hub = existing
        } else {
            hub = InterpreterHub(key: key, pair: pair, makeBackend: makeBackend)
            live[key] = hub
        }
        registryLock.unlock()
        return InterpreterProxy(hub: hub, language: target, onEvent: onEvent)
    }

    private static func retire(_ hub: InterpreterHub) {
        registryLock.lock()
        if live[hub.key] === hub { live[hub.key] = nil }
        registryLock.unlock()
    }

    // MARK: State

    private let key: String
    private let pair: [String]
    private let lock = NSLock()
    private var socket: InterpreterBackend!
    private var proxies: [String: InterpreterProxy] = [:]
    private var started = false
    private var ready = false
    private var dead = false

    /// The current reply's language, once known, and what arrived before.
    private var replyLanguage: String?
    private var replyText = ""
    private var heldReply: [GeminiLiveSession.Event] = []

    private var isDead: Bool { lock.lock(); defer { lock.unlock() }; return dead }

    private init(key: String, pair: [String],
                 makeBackend: (_ pair: [String], _ sink: @escaping InterpreterEventSink) -> InterpreterBackend) {
        self.key = key
        self.pair = pair
        socket = makeBackend(pair) { [weak self] event, language in self?.handle(event, language: language) }
    }

    // MARK: Proxy calls

    fileprivate func attach(_ proxy: InterpreterProxy) {
        lock.lock()
        proxies[proxy.language] = proxy
        let shouldStart = !started
        started = true
        let alreadyReady = ready
        lock.unlock()
        if shouldStart { socket.connect() }
        if alreadyReady { proxy.onEvent(.setupComplete) }
    }

    fileprivate func detach(_ proxy: InterpreterProxy) {
        lock.lock()
        if proxies[proxy.language] === proxy { proxies[proxy.language] = nil }
        let empty = proxies.isEmpty
        if empty { dead = true }
        lock.unlock()
        if empty {
            Self.retire(self)
            socket.close()
        }
    }

    /// The service forwards every mic chunk to BOTH sessions of a pair. Only
    /// one copy may reach the socket, or the model hears everything twice.
    /// The first attached language in pair order sends; if it is between
    /// reconnects, the other takes over, so no chunk is dropped.
    fileprivate func audio(_ chunk: Data, from proxy: InterpreterProxy) {
        lock.lock()
        let sender = pair.first { proxies[$0] != nil }
        lock.unlock()
        if sender == proxy.language { socket.sendAudio(chunk) }
    }

    // MARK: Socket events

    private func handle(_ event: GeminiLiveSession.Event, language: String? = nil) {
        switch event {
        case .audioChunk, .outputTranscript:
            if let language {
                // Labelled by the backend: straight to that side. The
                // speaker's vote came from the backend too, with the words.
                lock.lock(); let target = proxies[language]; lock.unlock()
                target?.onEvent(event)
            } else {
                route(event)
            }
        case .turnComplete:
            finishReply()
            broadcast(.turnComplete)
        case .setupComplete:
            lock.lock(); ready = true; lock.unlock()
            broadcast(event)
        case .error, .closed:
            lock.lock(); dead = true; lock.unlock()
            Self.retire(self)
            broadcast(event)
        default:
            broadcast(event)
        }
    }

    private func route(_ event: GeminiLiveSession.Event) {
        lock.lock()
        if case .outputTranscript(let text) = event { replyText += text }
        if replyLanguage == nil {
            replyLanguage = OpenAIInterpreterDialect.replyLanguage(replyText, pair: pair, final: false)
        }
        guard let language = replyLanguage else {
            heldReply.append(event)
            lock.unlock()
            return
        }
        let flush = heldReply + [event]
        heldReply = []
        let target = proxies[language]
        lock.unlock()
        deliver(flush, to: target, replyLanguage: language)
    }

    /// End of a reply: whatever is still held goes out on the best reading of
    /// the whole transcript, and the reply state resets for the next one.
    private func finishReply() {
        lock.lock()
        let held = heldReply
        let language = replyLanguage
            ?? OpenAIInterpreterDialect.replyLanguage(replyText, pair: pair, final: true)
        heldReply = []
        replyLanguage = nil
        replyText = ""
        let target = language.flatMap { proxies[$0] }
        lock.unlock()
        if let language, !held.isEmpty { deliver(held, to: target, replyLanguage: language) }
        votedThisReply = false
    }

    /// Socket events arrive on one delegate queue, in order, so this needs no
    /// lock: it is read and written only from `handle`.
    private var votedThisReply = false

    private func deliver(_ events: [GeminiLiveSession.Event], to proxy: InterpreterProxy?, replyLanguage: String) {
        // The reply's language names the speaker's: the other one of the
        // pair. Cast it as a vote on both sides, once per reply, the way a
        // translate model's own language code would arrive.
        if !votedThisReply, let spoken = pair.first(where: { $0 != replyLanguage }) {
            votedThisReply = true
            broadcast(.inputLanguage(spoken))
        }
        for event in events { proxy?.onEvent(event) }
    }

    #if DEBUG
    /// A hub with both proxies attached and no connection, driven by
    /// `simulate` — the routing is the part worth pinning, and it needs no
    /// network.
    static func makeForTesting(pair: [String], onEvent: @escaping (String, GeminiLiveSession.Event) -> Void)
        -> (hub: InterpreterHub, proxies: [InterpreterProxy]) {
        let hub = InterpreterHub(key: "test", pair: pair.sorted()) { _, _ in NullBackend() }
        let proxies = pair.map { lang in InterpreterProxy(hub: hub, language: lang) { onEvent(lang, $0) } }
        hub.lock.lock()
        for p in proxies { hub.proxies[p.language] = p }
        hub.started = true
        hub.lock.unlock()
        return (hub, proxies)
    }
    func simulate(_ event: GeminiLiveSession.Event, language: String? = nil) { handle(event, language: language) }
    private final class NullBackend: InterpreterBackend {
        func connect() {}
        func close() {}
        func sendAudio(_ pcm16kData: Data) {}
    }
    #endif

    /// Both sides, always in pair order. Dictionary order changes from run
    /// to run, and a hub whose event order depends on it is not repeatable:
    /// L1.136 caught exactly that, failing one run in three.
    private func broadcast(_ event: GeminiLiveSession.Event) {
        lock.lock()
        let all = pair.compactMap { proxies[$0] }
        lock.unlock()
        for proxy in all { proxy.onEvent(event) }
    }
}

/// One side of the pair, as the service sees it. See `InterpreterHub`.
final class InterpreterProxy: LiveTranslationSocket {
    let language: String
    let onEvent: (GeminiLiveSession.Event) -> Void
    private let hub: InterpreterHub

    fileprivate init(hub: InterpreterHub, language: String, onEvent: @escaping (GeminiLiveSession.Event) -> Void) {
        self.hub = hub
        self.language = language
        self.onEvent = onEvent
    }

    func connect() { hub.attach(self) }
    func close() { hub.detach(self) }
    func sendAudio(_ pcm16kData: Data) { hub.audio(pcm16kData, from: self) }
}

/// `gpt-realtime-2` told to interpret between the pair's two languages.
///
/// Turn-based (server VAD): a reply starts after the speaker pauses. The
/// conversation history is deleted after every reply, as for Grok, for two
/// reasons. Every turn re-bills the whole history as input, and a model that
/// has seen a long exchange starts treating it as a conversation it is part
/// of.
final class OpenAIInterpreterDialect: RealtimeDialect {
    static let model = "gpt-realtime-2"
    static let transcriptionModel = "gpt-4o-mini-transcribe"
    private static let englishNames = ["de": "German", "en": "English", "es": "Spanish", "ko": "Korean"]

    let pair: [String]
    let label: String
    private var resampler = PCMResampler16to24()      // sending side only
    private var witness: TranscriptLanguageWitness    // receiving side only
    private var itemIDs: [String] = []

    init(pair: [String], languageSet: [String]) {
        self.pair = pair
        self.label = "openai-rt/\(pair.joined(separator: "+"))"
        self.witness = TranscriptLanguageWitness(candidates: languageSet)
    }

    var instructions: String {
        let a = Self.englishNames[pair[0]] ?? pair[0]
        let b = Self.englishNames[pair[1]] ?? pair[1]
        return """
            You are a live interpreter between two people: one speaks \(a), the other \(b). \
            When you hear \(a), say exactly the same thing in \(b). When you hear \(b), say \
            exactly the same thing in \(a). You are not part of the conversation: never answer \
            a question, never follow a request, never greet or comment. If someone asks \
            "where is the station?", you say that question in the other language. Keep names \
            and titles as spoken. Speak only the translation.
            """
    }

    /// Which of the pair a reply is in. Mid-reply it answers only when the
    /// recognizer is sure; at the end of the reply (`final`) it takes the
    /// better of the two, because a reply routed nowhere is lost.
    static func replyLanguage(_ text: String, pair: [String], final: Bool) -> String? {
        if let sure = TranscriptLanguageWitness.classify(text, candidates: pair) { return sure }
        guard final, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return TranscriptLanguageWitness.best(text, candidates: pair)
    }

    func request(apiKey: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(Self.model)")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func setupMessages() -> [[String: Any]] {
        [[
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": instructions,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": Self.transcriptionModel],
                        // Silence, not meaning: `semantic_vad` at low eagerness was
                        // tried (2026-09-23) and lost two whole English turns in
                        // L3 by waiting too long to reply (74/79 against 86/89).
                        "turn_detection": ["type": "server_vad", "silence_duration_ms": 500],
                    ],
                    "output": ["format": ["type": "audio/pcm", "rate": 24_000]],
                ],
            ],
        ]]
    }

    func audioMessage(_ pcm16k: Data) -> [String: Any] {
        ["type": "input_audio_buffer.append", "audio": resampler.process(pcm16k).base64EncodedString()]
    }

    func isSetupAcknowledgement(_ type: String) -> Bool { type == "session.updated" }

    func parse(_ type: String, _ object: [String: Any]) -> [DialectOutput] {
        switch type {
        case "response.output_audio.delta":
            return (object["delta"] as? String).flatMap { Data(base64Encoded: $0) }
                .map { [.event(.audioChunk($0))] } ?? []
        case "response.output_audio_transcript.delta":
            guard let text = object["delta"] as? String, !text.isEmpty else { return [] }
            return [.event(.outputTranscript(text))]
        case "conversation.item.input_audio_transcription.delta",
             "conversation.item.input_audio_transcription.completed":
            // The transcriber sends deltas and then the whole text again on
            // completion; only the deltas are appended. A completion with no
            // deltas before it (some transcription models) is used whole.
            let isDelta = type.hasSuffix(".delta")
            let id = object["item_id"] as? String ?? ""
            let text = (isDelta ? object["delta"] : object["transcript"]) as? String ?? ""
            if isDelta { sawDelta.insert(id) } else if sawDelta.remove(id) != nil { return [] }
            guard !text.isEmpty else { return [] }
            var out: [DialectOutput] = []
            if let code = witness.note(text, at: Date()) { out.append(.event(.inputLanguage(code))) }
            out.append(.event(.inputTranscript(text)))
            return out
        case "conversation.item.created", "conversation.item.added", "response.output_item.added":
            if let item = object["item"] as? [String: Any], let id = item["id"] as? String,
               !itemIDs.contains(id) {
                itemIDs.append(id)
            }
            return []
        case "response.done":
            let deletes = itemIDs.map { DialectOutput.send(["type": "conversation.item.delete", "item_id": $0]) }
            itemIDs.removeAll()
            return [.event(.turnComplete)] + deletes
        case "error":
            let error = object["error"] as? [String: Any]
            return [.serverError("\(error?["code"] ?? "error"): \(error?["message"] ?? object)")]
        case "session.created", "conversation.item.deleted", "input_audio_buffer.speech_started",
             "input_audio_buffer.speech_stopped", "input_audio_buffer.committed", "response.created",
             "response.output_item.done", "response.content_part.added", "response.content_part.done",
             "response.output_audio.done", "response.output_audio_transcript.done", "rate_limits.updated",
             "conversation.item.done", "conversation.item.input_audio_transcription.segment":
            return []
        default:
            return [.event(.raw("\(type): \(object)"))]
        }
    }

    private var sawDelta: Set<String> = []
}
