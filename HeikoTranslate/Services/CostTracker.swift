import Foundation

/// Running tally of what this app has cost in Gemini Live API usage, kept
/// across launches. Surfaced by tapping the version number.
///
/// Tokens come from the server's own `usageMetadata` frames, whose shape was
/// measured against the live API on 2026-07-27:
///
/// ```json
/// {"promptTokenCount":25,
///  "promptTokensDetails":[{"modality":"TEXT","tokenCount":581},
///                         {"modality":"AUDIO","tokenCount":25}],
///  "responseTokenCount":25,
///  "responseTokensDetails":[{"modality":"AUDIO","tokenCount":25}],
///  "totalTokenCount":50}
/// ```
///
/// The AUDIO figures are **incremental** per frame (steady at 25 while
/// audio flows) and are what's tallied here. The TEXT figure is the running
/// instruction context and *grows* frame to frame (535 → 559 → 575 → 581),
/// so adding it up would multiply-count the same context hundreds of times;
/// it's deliberately excluded. Audio dominates the bill in this app anyway —
/// three sessions stream audio for every minute the mic is open.
///
/// The result is therefore an **estimate**, and the UI says so.
@MainActor
final class CostTracker: ObservableObject {
    static let shared = CostTracker()

    /// Google's published per-token pricing for the dedicated Live Translate
    /// model: $3.50 / 1M audio-input tokens, $21 / 1M audio-output tokens.
    /// Check ai.google.dev/gemini-api/docs/pricing before relying on these.
    static let audioInputUSDPerToken = 3.50 / 1_000_000
    static let audioOutputUSDPerToken = 21.0 / 1_000_000

    private enum Key {
        static let inputTokens = "cost.audioInputTokens"
        static let outputTokens = "cost.audioOutputTokens"
        static let since = "cost.trackingStartedAt"
    }

    @Published private(set) var audioInputTokens: Int
    @Published private(set) var audioOutputTokens: Int
    /// When counting began — this can only ever be the first launch of a
    /// build that had this tracker in it, not the true first build.
    @Published private(set) var trackingStartedAt: Date

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        audioInputTokens = defaults.integer(forKey: Key.inputTokens)
        audioOutputTokens = defaults.integer(forKey: Key.outputTokens)
        if let stored = defaults.object(forKey: Key.since) as? Date {
            trackingStartedAt = stored
        } else {
            let now = Date()
            trackingStartedAt = now
            defaults.set(now, forKey: Key.since)
        }
    }

    /// Tally one `usageMetadata` frame.
    func record(usage: [String: Any]) {
        let input = Self.audioTokens(in: usage["promptTokensDetails"])
        let output = Self.audioTokens(in: usage["responseTokensDetails"])
        guard input > 0 || output > 0 else { return }
        audioInputTokens += input
        audioOutputTokens += output
        defaults.set(audioInputTokens, forKey: Key.inputTokens)
        defaults.set(audioOutputTokens, forKey: Key.outputTokens)
    }

    private static func audioTokens(in details: Any?) -> Int {
        guard let rows = details as? [[String: Any]] else { return 0 }
        return rows
            .filter { ($0["modality"] as? String)?.uppercased() == "AUDIO" }
            .compactMap { $0["tokenCount"] as? Int }
            .reduce(0, +)
    }

    var estimatedCostUSD: Double {
        Double(audioInputTokens) * Self.audioInputUSDPerToken
            + Double(audioOutputTokens) * Self.audioOutputUSDPerToken
    }

    /// Google bills audio at 25 tokens per second, so the token counts double
    /// as a running stopwatch of how much audio has crossed the wire.
    static let tokensPerAudioSecond = 25.0
    var audioMinutesIn: Double { Double(audioInputTokens) / Self.tokensPerAudioSecond / 60 }
    var audioMinutesOut: Double { Double(audioOutputTokens) / Self.tokensPerAudioSecond / 60 }

    var inputCostUSD: Double { Double(audioInputTokens) * Self.audioInputUSDPerToken }
    var outputCostUSD: Double { Double(audioOutputTokens) * Self.audioOutputUSDPerToken }

    /// Wipe the tally (from the cost sheet).
    func reset() {
        audioInputTokens = 0
        audioOutputTokens = 0
        trackingStartedAt = Date()
        defaults.set(0, forKey: Key.inputTokens)
        defaults.set(0, forKey: Key.outputTokens)
        defaults.set(trackingStartedAt, forKey: Key.since)
    }
}
