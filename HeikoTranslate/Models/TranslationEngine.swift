import Foundation

/// Which vendor's live speech translation the two sessions ride.
///
/// Everything above the session — turn arbitration, audio I/O, reconnects,
/// R1–R8 — is shared. An engine only decides which wire protocol each of the
/// two fixed-target sessions speaks, which is why this is a small enum and
/// not a second orchestrator: a second copy of the turn machinery would drift
/// from the first, and the drift would be invisible until a device run.
///
/// - `gemini`: `gemini-3.5-live-translate-preview`. A translate model with a
///   fixed output language; reports the detected input language itself.
/// - `openAI`: `gpt-realtime-translate` on the dedicated translation
///   endpoint. The same shape as Gemini — one output language per session,
///   source auto-detected — but it reports no language code, so the input
///   language is read off its transcript on the device
///   (`TranscriptLanguageWitness`).
/// - `openAIRealtime`: ONE `gpt-realtime-2` session interpreting both
///   directions, told so by its instructions (`InterpreterHub`). Half the
///   sessions of `openAI`; who spoke is read from the language of its reply.
/// - `soniox`: ONE Soniox stream transcribing and translating both ways
///   (`two_way`), every token labelled with its language, spoken by Soniox's
///   own voice (`SonioxBackend`). Text first, then a synthetic voice, at a
///   fraction of the others' price.
/// - `grok`: xAI's voice agent (`grok-voice-latest`), a general speech model
///   told by its instructions to act as a one-way interpreter. Turn-based
///   (server VAD), so its output arrives after the speaker pauses rather
///   than alongside the speech.
enum TranslationEngine: String, CaseIterable, Identifiable {
    case gemini
    case openAI = "openai"
    case openAIRealtime = "openai-realtime"
    case soniox
    case grok

    var id: String { rawValue }

    static let `default`: TranslationEngine = .gemini

    /// Where the choice is persisted.
    static let defaultsKey = "settings.engine"

    /// Vendor names, shown as-is in every UI language: a brand is not
    /// translated, and the picker is a developer control that happens to
    /// live on Heiko's sheet.
    var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .openAI: return "OpenAI Translate"
        case .openAIRealtime: return "OpenAI Realtime"
        case .soniox: return "Soniox"
        case .grok: return "Grok"
        }
    }

    /// The `Secrets.plist` entry holding this engine's key.
    var secretsKey: String {
        switch self {
        case .gemini: return "GEMINI_API_KEY"
        case .openAI, .openAIRealtime: return "OPENAI_API_KEY"
        case .soniox: return "SONIOX_API_KEY"
        case .grok: return "XAI_API_KEY"
        }
    }

    /// A stored value this build does not know (a removed engine, a typo in
    /// a launch argument) falls back to the default rather than failing.
    static func load(from defaults: UserDefaults = .standard) -> TranslationEngine {
        defaults.string(forKey: defaultsKey).flatMap(TranslationEngine.init(rawValue:)) ?? .default
    }
}
