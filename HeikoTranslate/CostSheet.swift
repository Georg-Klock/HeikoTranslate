import SwiftUI

/// Running Gemini API spend. Presented from the **Nutzung** row in
/// `LanguageSettingsSheet`, which is visible to anyone who opens settings —
/// it is no longer the hidden version-number tap this comment used to claim,
/// and a comment that lies about reachability is worse than none. Still in
/// English: it is a developer affordance, and Heiko has no reason to open it.
/// If it should be hard to find again, that is a design decision to make in
/// `LanguageSettingsSheet`, not a comment to restore here. GitHub #28.
struct CostSheet: View {
    @ObservedObject private var tracker = CostTracker.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false

    /// Built once on appear, not inside `body` — see GitHub #6. This sheet
    /// re-renders on every tracker update, and the tracker updates while a
    /// conversation is running.
    @State private var logFile: URL?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private func usd(_ value: Double) -> String {
        value < 0.01 && value > 0 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }

    private func tokens(_ count: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Total")
                            .font(.headline)
                        Spacer()
                        Text(usd(tracker.estimatedCostUSD))
                            .font(.system(.title2, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Estimated from the server's own token counts, since \(Self.dateFormatter.string(from: tracker.trackingStartedAt)). Roughly \(String(format: "%.1f", tracker.audioMinutesIn)) min in / \(String(format: "%.1f", tracker.audioMinutesOut)) min out.")
                }

                Section("Audio in") {
                    LabeledContent("Tokens", value: tokens(tracker.audioInputTokens))
                    LabeledContent("Cost", value: usd(tracker.inputCostUSD))
                }

                Section("Audio out") {
                    LabeledContent("Tokens", value: tokens(tracker.audioOutputTokens))
                    LabeledContent("Cost", value: usd(tracker.outputCostUSD))
                }

                Section {
                    if let file = logFile {
                        ShareLink(item: file) {
                            Label("Share diagnostic log", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Every recorded run in one file. AirDrop it to the Mac — no cable needed, which has repeatedly been the thing standing between a bug and its diagnosis.")
                }

                Section {
                    Button("Reset counter", role: .destructive) { confirmingReset = true }
                } footer: {
                    Text("gemini-3.5-live-translate-preview, verified 27 Jul 2026: audio in $3.50/1M tokens ($0.0053/min), audio out $21/1M tokens ($0.0315/min), billed at 25 tokens per second of audio. Text context tokens are excluded — the API re-reports the same running context every frame, so summing them would multiply-count it. Both sessions of the language pair stream while the mic is open.")
                }
            }
            .task {
                logFile = await Task.detached(priority: .utility) {
                    DiagnosticLog.shared.exportedFile()
                }.value
            }
            .navigationTitle("API cost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Reset the cost counter?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { tracker.reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sets both token counts to zero and starts counting from now.")
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    CostSheet()
}
