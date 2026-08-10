import Foundation
import UIKit

/// Sends the diagnostic log home by itself, so nobody in Germany has to find
/// a share sheet.
///
/// The manual route (Settings → "Protokoll an Georg senden") stays, because
/// it works with no configuration and no network agreement. This is the
/// automatic one: when the app goes to the background after a session that
/// actually did something, it POSTs the current log file to
/// `AppConfig.diagnosticUploadURL`.
///
/// **It is off unless that URL is set.** With no URL, this type does nothing
/// at all — no request, no queue, no stored state.
///
/// Deliberately unreliable-by-design: one attempt, short timeout, silent
/// failure, no retry queue. A lost log costs one debugging round; a retry
/// loop chewing a traveller's cellular data costs real money and trust. The
/// file is kept on the device either way, and five runs are retained.
enum LogUploader {

    /// Uploads at most this often, so a session of repeated backgrounding
    /// does not turn into repeated uploads of nearly the same file.
    private static let minimumInterval: TimeInterval = 120
    private static var lastUploadAt: Date = .distantPast
    private static let defaultsKey = "diagnostics.lastUploadedBytes"

    static var isEnabled: Bool { AppConfig.diagnosticUploadURL != nil }

    /// Call when the app backgrounds or a session ends. Returns immediately.
    static func uploadCurrentLog(reason: String) {
        guard let endpoint = AppConfig.diagnosticUploadURL else { return }
        guard Date().timeIntervalSince(lastUploadAt) > minimumInterval else { return }

        let url = DiagnosticLog.currentURL
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }

        // Nothing new since the last send? Then there is nothing to learn.
        let previously = UserDefaults.standard.integer(forKey: defaultsKey)
        guard data.count != previously else { return }

        lastUploadAt = Date()
        let device = UIDevice.current
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        let stamp = ISO8601DateFormatter().string(from: Date())

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\(version) (\(build))", forHTTPHeaderField: "X-App-Version")
        request.setValue(device.systemVersion, forHTTPHeaderField: "X-iOS-Version")
        request.setValue(reason, forHTTPHeaderField: "X-Upload-Reason")
        request.setValue("heiko-\(stamp).log", forHTTPHeaderField: "X-Log-Name")
        request.httpBody = data

        // Ask iOS for a moment to finish while backgrounding, and give it
        // back whatever happens — never hold the app open.
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "diagnostic-upload") {
            if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if error == nil, (200..<300).contains(code) {
                UserDefaults.standard.set(data.count, forKey: defaultsKey)
                diag("upload", "diagnostic log sent (\(data.count) bytes, \(reason))")
            } else {
                diag("upload", "diagnostic log NOT sent (\(error?.localizedDescription ?? "HTTP \(code)")) — kept on device")
            }
            if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
        }.resume()
    }
}
