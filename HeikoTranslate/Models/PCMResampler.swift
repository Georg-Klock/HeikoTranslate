import Foundation

/// 16kHz → 24kHz for 16-bit little-endian mono PCM, streamed chunk by chunk.
///
/// The mic path produces 16kHz (what Gemini takes); OpenAI's translation
/// endpoint accepts only 24kHz. Linear interpolation is enough for speech
/// going into a recognizer. The one thing that matters is **continuity
/// across chunks**: each chunk's first output samples interpolate from the
/// previous chunk's last input sample, so ~10 chunk seams a second do not
/// each become a click the model has to hear through.
///
/// The ratio is exactly 3:2, so output positions fall on a fixed grid of
/// input thirds and no floating-point phase can drift over a long session.
struct PCMResampler16to24 {

    /// The last input sample of the previous chunk, or nil before the first.
    private var previous: Int16?
    /// Where the next output sample sits, in thirds of an input sample,
    /// measured from `previous` (0 = on it). Always 0, 2, or 1 at a seam.
    private var phaseThirds = 0

    mutating func process(_ pcm16k: Data) -> Data {
        let inputCount = pcm16k.count / 2
        guard inputCount > 0 else { return Data() }
        var samples = [Int16](repeating: 0, count: inputCount)
        pcm16k.withUnsafeBytes { raw in
            for i in 0..<inputCount {
                samples[i] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
            }
        }
        // Timeline: index 0 is `previous` (or the first sample, duplicated,
        // on the very first chunk), then this chunk's samples.
        let timeline = [previous ?? samples[0]] + samples
        var out: [Int16] = []
        out.reserveCapacity(inputCount * 3 / 2 + 2)
        var position = phaseThirds          // in thirds of a sample
        let last = (timeline.count - 1) * 3 // the newest sample, in thirds
        // Only positions strictly before the newest sample: the newest one
        // becomes next chunk's `previous`, and emitting it here too would
        // emit it twice.
        while position < last {
            let index = position / 3, frac = position % 3
            let a = Int(timeline[index]), b = Int(timeline[index + 1])
            out.append(Int16(clamping: a + (b - a) * frac / 3))
            position += 2                   // 16k → 24k: step 2/3 of a sample
        }
        phaseThirds = position - last
        previous = samples[inputCount - 1]
        return out.withUnsafeBufferPointer { buffer in
            var data = Data(capacity: buffer.count * 2)
            for s in buffer { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
            return data
        }
    }
}
