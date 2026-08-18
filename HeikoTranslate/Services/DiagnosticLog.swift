import Foundation

/// Append-only diagnostic log written to a file on the device, so a session
/// out in the world can be examined afterwards instead of reconstructed from
/// memory. Pull it with `Tools/pull_logs.sh`.
///
/// This app is still being shaken out on real hardware, and its hardest bugs
/// (nothing captured at launch, a turn ending mid-sentence, the wrong side)
/// are all timing bugs that don't reproduce on demand. Console prints only
/// help while tethered to Xcode; this survives the walk back to the desk.
///
/// Safe to call from any thread, including the audio tap.
final class DiagnosticLog {
    static let shared = DiagnosticLog()

    /// Current log. Older runs are kept alongside as `.1` … `.4`.
    ///
    /// Retention matters more than it looks: getting files off the phone has
    /// repeatedly failed (charge-only cable, stale Wi-Fi tunnel), and each
    /// failed attempt used to cost us a run because launching the app again
    /// rotated the interesting one away.
    static let keptRuns = 5

    /// Where the log files live. `Documents/` in the app; tests inject a
    /// temporary directory so they can write through the real type without
    /// touching the app container.
    let directory: URL

    var currentURL: URL {
        logURL(index: 0)
    }
    func logURL(index: Int) -> URL {
        let base = directory.appendingPathComponent("heiko-diagnostics.log")
        return index == 0 ? base : base.appendingPathExtension("\(index)")
    }

    private let queue = DispatchQueue(label: "diagnostic-log", qos: .utility)
    private var handle: FileHandle?
    private let launchedAt = Date()
    private var bytesWritten = 0
    private let maxBytes = 4 * 1024 * 1024

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private convenience init() {
        self.init(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
    }

    init(directory: URL) {
        self.directory = directory
        queue.async { [self] in
            rotateIfNeeded(force: false)
            openHandle()
        }
        // Short version AND build, matching the on-screen pill exactly — the
        // same `AppVersion.label` the pill renders, rather than a second copy
        // of the formatting that could drift from it. The marketing version no
        // longer moves between releases, so it alone cannot say which build
        // wrote a log — and a log from Heiko in Germany that cannot be tied to
        // a build is most of its value gone. On an experiment build the label
        // carries the tag too, so the log says which experiment it came from.
        log("app", "=== launch: Heiko Translate \(AppVersion.label), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    /// The log carries both speakers' words, and `Documents/` rides iCloud
    /// and local backups by default — the one automatic copy the "logs never
    /// leave the phone by themselves" promise (#8) did not cover until #92.
    /// Set unconditionally, not just at creation: files written before this
    /// existed, and files rotated by a move (which can shed the attribute),
    /// must end up excluded too.
    private static func excludeFromBackup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try? url.setResourceValues(values)
    }

    private func openHandle() {
        let url = currentURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        Self.excludeFromBackup(url)
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        bytesWritten = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) as? Int ?? 0
    }

    /// Start a fresh file each launch, keeping exactly one previous run — the
    /// bug is usually in the run you just did, and the one before it is
    /// enough context for "did it work last time?".
    private func rotateIfNeeded(force: Bool) {
        let fm = FileManager.default
        guard force || fm.fileExists(atPath: currentURL.path) else { return }
        // Shift .3 → .4, .2 → .3, … , current → .1, dropping the oldest.
        try? fm.removeItem(at: logURL(index: Self.keptRuns - 1))
        for index in stride(from: Self.keptRuns - 2, through: 0, by: -1) {
            let from = logURL(index: index)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.moveItem(at: from, to: logURL(index: index + 1))
        }
        // Re-mark every kept run: the moves above can shed the attribute,
        // and runs written before the exclusion existed pick it up here.
        for index in 1..<Self.keptRuns {
            Self.excludeFromBackup(logURL(index: index))
        }
        handle = nil
        bytesWritten = 0
    }

    /// One line. `category` is a short tag: app, audio, session, turn, ui.
    func log(_ category: String, _ message: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(launchedAt)
        queue.async { [self] in
            if handle == nil { openHandle() }
            let line = String(
                format: "%@ +%7.3f [%@] %@\n",
                Self.stamp.string(from: now), elapsed, category, message
            )
            guard let data = line.data(using: .utf8) else { return }
            handle?.write(data)
            bytesWritten += data.count
            if bytesWritten > maxBytes {
                // Don't let a long session fill the phone.
                try? handle?.close()
                rotateIfNeeded(force: true)
                openHandle()
            }
        }
    }

    /// Flush before the app can be suspended.
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    /// Write every kept run to one file and return it, for sharing straight
    /// off the phone. Pulling over the cable keeps failing (charge-only
    /// cable, locked phone, stale Wi-Fi tunnel), and a log that can't be
    /// retrieved is worth nothing — this path needs no Mac at all.
    func exportedFile() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heiko-diagnostics-all.log")
        do {
            try exportText().write(to: url, atomically: true, encoding: .utf8)
            // tmp/ is not backed up today, but that is an OS default, not a
            // promise — mark the one file that concatenates every kept run.
            Self.excludeFromBackup(url)
            return url
        } catch {
            return nil
        }
    }

    /// Everything currently on disk, newest run first — for sharing from the
    /// cost sheet.
    func exportText() -> String {
        flush()
        return (0..<Self.keptRuns).compactMap { index -> String? in
            guard let text = try? String(contentsOf: logURL(index: index), encoding: .utf8),
                  !text.isEmpty else { return nil }
            return "===== run -\(index) =====\n\(text)"
        }.joined(separator: "\n")
    }
}

/// Convenience so call sites stay short.
func diag(_ category: String, _ message: String) {
    DiagnosticLog.shared.log(category, message)
}
