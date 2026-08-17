import Foundation
import Speech

/// Whether the referee's coverage is something the APP can arrange (#135).
///
/// The first device run found only `de` and `en` available to
/// `SFSpeechRecognizer`, and the experiment was written off on the reasoning
/// that the missing models could only be installed by the owner enabling
/// dictation languages in Settings — a setup step refused as a product
/// decision, since Heiko never opens settings.
///
/// **That reasoning was wrong for iOS 26.** The new Speech framework exposes
/// asset management to the app directly:
///
/// - `SpeechTranscriber.supportedLocales` — what this OS can transcribe
/// - `SpeechTranscriber.installedLocales` — what is on the device now
/// - `AssetInventory.assetInstallationRequest(supporting:)` →
///   `downloadAndInstall()` — a background download with a `Progress`, no UI,
///   no Settings, no keyboards
/// - `AssetInventory.reserve(locale:)` / `maximumReservedLocales` — an app may
///   hold only so many locales at once, which is the real constraint to
///   measure
///
/// So the question changes from "has the owner configured their phone?" to
/// "does the OS support these locales, and how many may we hold?". This probe
/// answers exactly that, and reports the OLD API's verdict beside the new one
/// — because the referee currently runs on `SFSpeechRecognizer`, and whether
/// installing a `SpeechTranscriber` asset also satisfies it is an open
/// question that only a device can settle.
///
/// Report-only by default. Installing is gated behind `allowDownload`, which
/// the caller sets from an unmetered network path — models are large and a
/// silent cellular download would be its own kind of rudeness.
@available(iOS 26.0, *)
enum SpeechAssetProbe {

    static func run(allowDownload: Bool) async {
        let all = TurnLogic.Lang.allCases
        let supported = await SpeechTranscriber.supportedLocales.map(\.identifier)
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier)

        DiagnosticLog.shared.log("referee", "SpeechTranscriber supported=\(supported.count) installed=\(installed.count) maxReserved=\(AssetInventory.maximumReservedLocales) reserved=\(await AssetInventory.reservedLocales.map(\.identifier).joined(separator: ","))")

        // Per language, the new API's two answers beside the old API's one.
        // `hasPrefix` on the language code rather than an exact match: the
        // OS may list "de-DE" where we ask for "de-DE", but also "es-419"
        // where we ask for "es-MX", and a mismatch there would read as
        // "unsupported" when it is really "spelled differently".
        let rows = all.map { lang -> String in
            let wanted = RefereeEvidence.speechLocaleIdentifier(for: lang)
            let code = String(wanted.prefix(2))
            let isSupported = supported.contains { $0.hasPrefix(code) }
            let isInstalled = installed.contains { $0.hasPrefix(code) }
            let old = SFSpeechRecognizer(locale: Locale(identifier: wanted))?.supportsOnDeviceRecognition ?? false
            return "\(lang.rawValue)[new:\(isSupported ? "sup" : "NO")/\(isInstalled ? "inst" : "notinst") old:\(old ? "on-device" : "NO")]"
        }
        DiagnosticLog.shared.log("referee", "assets " + rows.joined(separator: " "))

        // The exact identifiers, once, so a mismatch between what we ask for
        // and what the OS calls it is visible rather than inferred.
        DiagnosticLog.shared.log("referee", "supportedLocales: \(supported.sorted().joined(separator: ","))")
        DiagnosticLog.shared.log("referee", "installedLocales: \(installed.sorted().joined(separator: ","))")

        guard allowDownload else {
            DiagnosticLog.shared.log("referee", "install skipped (metered or disallowed network)")
            return
        }
        await installPairIfNeeded(supported: supported, installed: installed)
    }

    /// Install the current pair PLUS the languages under measurement.
    ///
    /// The pair alone was the first design, and it has a hole: switching the
    /// pair mid-session does not re-run this probe, which fires once at
    /// launch, so a fresh partner language would stay uninstalled until the
    /// next cold start. #135 is measuring de↔fr AND de↔es, so both are
    /// fetched up front.
    ///
    /// `maximumReservedLocales` (5) caps RESERVATIONS, not installs — the
    /// device already reported 12 installed locales — so a handful of installs
    /// is within bounds. This list stays small and explicit rather than
    /// becoming "install everything": the app has eight languages, most of
    /// which are not being measured, and each asset is a real download.
    private static func installPairIfNeeded(supported: [String], installed: [String]) async {
        let defaults = UserDefaults.standard
        let home = TurnLogic.Lang(rawValue: defaults.string(forKey: "settings.homeLang") ?? "de") ?? .de
        let partner = TurnLogic.Lang(rawValue: defaults.string(forKey: "settings.partnerLang") ?? "en") ?? .en

        // de/es/fr are the #135 measurement set; the live pair is included so
        // an ordinary session is never left without its own languages.
        var targets: [TurnLogic.Lang] = [home, partner]
        for lang in [TurnLogic.Lang.es, .fr] where !targets.contains(lang) {
            targets.append(lang)
        }

        var modules: [any SpeechModule] = []
        var wantedNames: [String] = []
        for lang in targets {
            let wanted = RefereeEvidence.speechLocaleIdentifier(for: lang)
            let code = String(wanted.prefix(2))
            guard supported.contains(where: { $0.hasPrefix(code) }) else {
                DiagnosticLog.shared.log("referee", "install: \(lang.rawValue) not supported by this OS — nothing to fetch")
                continue
            }
            guard !installed.contains(where: { $0.hasPrefix(code) }) else { continue }
            // Match the OS's own spelling rather than ours, so a request for
            // es-MX does not miss an es-419 asset.
            let identifier = supported.first { $0.hasPrefix(code) } ?? wanted
            modules.append(SpeechTranscriber(locale: Locale(identifier: identifier),
                                             preset: .progressiveTranscription))
            wantedNames.append(identifier)
        }
        guard !modules.isEmpty else {
            DiagnosticLog.shared.log("referee", "install: \(targets.map(\.rawValue).joined(separator: ",")) already installed or unsupported")
            return
        }

        do {
            DiagnosticLog.shared.log("referee", "install: requesting \(wantedNames.joined(separator: ",")) …")
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                DiagnosticLog.shared.log("referee", "install: nothing to download (request nil — already satisfied)")
                return
            }
            try await request.downloadAndInstall()
            let now = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
            DiagnosticLog.shared.log("referee", "install: DONE — installedLocales now \(now.joined(separator: ","))")
            // The load-bearing follow-up: the referee runs on the OLD API, so
            // whether a new-API asset satisfies it is what decides whether any
            // of this helps without a rewrite.
            let oldNow = targets.map { lang -> String in
                let id = RefereeEvidence.speechLocaleIdentifier(for: lang)
                let ok = SFSpeechRecognizer(locale: Locale(identifier: id))?.supportsOnDeviceRecognition ?? false
                return "\(lang.rawValue)=\(ok ? "on-device" : "STILL-NO")"
            }
            DiagnosticLog.shared.log("referee", "install: old API after install — " + oldNow.joined(separator: " "))
        } catch {
            DiagnosticLog.shared.log("referee", "install FAILED: \(error.localizedDescription)")
        }
    }
}
