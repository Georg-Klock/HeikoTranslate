import Foundation

// Shared plumbing for the protocol-level test tools (L3 replay runner,
// L2.6 expiry probe). No top-level statements here — each tool has its own
// main.swift.

func loadAPIKey() -> String {
    let path = "HeikoTranslate/Resources/Secrets.plist"
    guard let data = FileManager.default.contents(atPath: path),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let key = plist["GEMINI_API_KEY"] as? String, !key.isEmpty
    else {
        fputs("error: run from the repo root with \(path) present (see README).\n", stderr)
        exit(2)
    }
    return key
}

/// Minimal RIFF/WAV reader. Requires the app's mic format: 16kHz, 16-bit,
/// mono PCM (Tools/make_test_audio.sh produces exactly this).
func loadWAV(_ path: String) -> Data {
    guard let file = FileManager.default.contents(atPath: path) else {
        fputs("error: cannot read \(path)\n", stderr); exit(2)
    }
    func u16(_ o: Int) -> Int { Int(file[o]) | Int(file[o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    func tag(_ o: Int) -> String { String(bytes: file[o..<o + 4], encoding: .ascii) ?? "" }

    guard file.count > 44, tag(0) == "RIFF", tag(8) == "WAVE" else {
        fputs("error: \(path) is not a WAV file\n", stderr); exit(2)
    }
    var offset = 12
    var pcm: Data?
    while offset + 8 <= file.count {
        let id = tag(offset), size = u32(offset + 4)
        let body = offset + 8
        if id == "fmt " {
            let format = u16(body), channels = u16(body + 2), rate = u32(body + 4), bits = u16(body + 14)
            guard format == 1, channels == 1, rate == 16000, bits == 16 else {
                fputs("error: \(path) must be 16kHz 16-bit mono PCM (got fmt=\(format) ch=\(channels) rate=\(rate) bits=\(bits))\n", stderr)
                exit(2)
            }
        } else if id == "data" {
            pcm = file.subdata(in: body..<min(body + size, file.count))
        }
        offset = body + size + (size % 2)
    }
    guard let pcm else { fputs("error: no data chunk in \(path)\n", stderr); exit(2) }
    return pcm
}

/// Same energy measure and threshold the service uses to gate playback.
func rms(_ pcm16: Data) -> Double {
    let count = pcm16.count / 2
    guard count > 0 else { return 0 }
    var sum = 0.0
    pcm16.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for i in 0..<count {
            let s = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
            sum += s * s
        }
    }
    return (sum / Double(count)).squareRoot()
}

/// The app writes diagnostics to a file on the device; these command-line
/// tools compile the same sources but have nowhere sensible to put one, so
/// they route the same calls to stderr, off by default.
///   L3_DIAG=1 Tools/l3replay.sh …
func diag(_ category: String, _ message: String) {
    guard ProcessInfo.processInfo.environment["L3_DIAG"] != nil else { return }
    FileHandle.standardError.write(Data("[\(category)] \(message)\n".utf8))
}
