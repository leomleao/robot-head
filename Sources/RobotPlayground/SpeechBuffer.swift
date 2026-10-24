// Speech-like audio for measuring lip-sync without a voice file: a low voice's
// buzz, cut into syllables at a talking pace with a breath between phrases. It
// is the level envelope that matters, not the words.

import AVFAudio

enum SpeechBuffer {
    /// `seconds` of mono float audio at `sampleRate`: a 150 Hz buzz in 3–6 Hz syllables,
    /// phrases of a few syllables, and pauses between them. The same every time.
    static func make(seconds: Double, sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let count = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let out = buffer.floatChannelData![0]

        // a fixed LCG, so every run hears the same speech
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(rng >> 11) / Double(1 << 53)
        }

        var i = 0
        let total = Int(count)
        while i < total {
            // a phrase of 2–6 syllables, then a pause of 0.2–0.7 s
            for _ in 0..<(2 + Int(random() * 5)) where i < total {
                let length = Int(sampleRate / (3 + random() * 3))
                let loudness = 0.5 + random() * 0.5
                for n in 0..<min(length, total - i) {
                    // each syllable swells and fades
                    let envelope = sin(Double.pi * Double(n) / Double(length))
                    let t = Double(i + n) / sampleRate
                    let buzz = sin(2 * .pi * 150 * t) + 0.5 * sin(2 * .pi * 300 * t) + 0.25 * sin(2 * .pi * 450 * t)
                    out[i + n] = Float(0.22 * loudness * envelope * buzz)
                }
                i += length
            }
            let pause = Int((0.2 + random() * 0.5) * sampleRate)
            for n in i..<min(total, i + pause) { out[n] = 0 }
            i += pause
        }
        return buffer
    }
}
