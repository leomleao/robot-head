import AVFAudio
import Foundation
import Testing
@testable import CharacterKit

@Suite struct AudioTests {
    private func sine(amplitude: Float, frames: Int, sampleRate: Double = 48_000, hz: Double = 220) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
    }

    @Test func mappingMatchesTheTypeScript() {
        #expect(AudioLevelMeter.level(rms: 0) == 0)
        #expect(AudioLevelMeter.level(rms: 0.012) == 0, "the gate")
        #expect(AudioLevelMeter.level(rms: 0.172) == 1, "the knee: fully open")
        #expect(AudioLevelMeter.level(rms: 0.5) == 1)
        #expect(abs(AudioLevelMeter.level(rms: 0.092) - pow(0.5, 0.75)) < 1e-6)
    }

    @Test func minus20dBFSSine() {
        // peak 0.1 → RMS 0.1/√2 ≈ 0.0707 → t ≈ 0.367 → level ≈ 0.471
        let samples = sine(amplitude: 0.1, frames: 4800)
        let r = samples.withUnsafeBufferPointer(rms)
        #expect(abs(r - 0.1 / Float(2).squareRoot()) < 1e-4)
        #expect(abs(AudioLevelMeter.level(rms: r) - 0.4713) < 1e-3)
    }

    @Test func blocksPlayOutWindowByWindow() {
        let meter = AudioLevelMeter()
        // 4096 samples at 48 kHz, four windows: silence, loud, quiet, silence
        let samples = [Float](repeating: 0, count: 1024) + sine(amplitude: 0.5, frames: 1024)
            + sine(amplitude: 0.1, frames: 1024) + [Float](repeating: 0, count: 1024)
        meter.process(samples: samples, sampleRate: 48_000, at: 100)
        let hop = 1024.0 / 48_000
        #expect(meter.level(at: 99.99) == 0, "not started yet")
        #expect(meter.level(at: 100 + 0.5 * hop) == 0)
        #expect(meter.level(at: 100 + 1.5 * hop) == 1)
        #expect(abs(meter.level(at: 100 + 2.5 * hop) - 0.4713) < 0.01)
        #expect(meter.level(at: 100 + 3.5 * hop) == 0)
    }

    @Test func oddBlocksSplitIntoNearlyEqualWindows() {
        let meter = AudioLevelMeter()
        // 4800 samples (100 ms) → five windows of 960
        let samples = sine(amplitude: 0.5, frames: 2880) + [Float](repeating: 0, count: 1920)
        meter.process(samples: samples, sampleRate: 48_000, at: 0)
        let hop = 960.0 / 48_000
        #expect(meter.level(at: 2.5 * hop) == 1)
        #expect(meter.level(at: 3.5 * hop) == 0)
    }

    @Test func aLaterBlockTakesOverWhenItStarts() {
        let meter = AudioLevelMeter()
        meter.process(samples: sine(amplitude: 0.5, frames: 4800), sampleRate: 48_000, at: 10)
        meter.process(samples: [Float](repeating: 0, count: 4800), sampleRate: 48_000, at: 10.05)
        #expect(meter.level(at: 10.04) == 1, "the earlier block plays until the next begins")
        #expect(meter.level(at: 10.06) == 0)
    }

    @Test func staleAudioClosesTheMouth() {
        let meter = AudioLevelMeter(staleAfter: 0.15)
        #expect(meter.level(at: 0) == 0, "nothing heard yet")
        meter.process(samples: sine(amplitude: 0.5, frames: 4800), sampleRate: 48_000, at: 5)
        #expect(meter.level(at: 5.2) == 1, "the last window holds a moment past the end")
        #expect(meter.level(at: 5.26) == 0, "a stopped engine must not leave the mouth open")
        #expect(meter.speechLevel == 0)
    }

    @Test func monoMixAveragesChannels() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        for i in 0..<4 {
            buffer.floatChannelData![0][i] = 1
            buffer.floatChannelData![1][i] = Float(i)
        }
        #expect(monoSamples(of: buffer) == [0.5, 1, 1.5, 2])
    }

    @Test func meterReadsWhileTheAudioThreadWrites() async {
        let meter = AudioLevelMeter()
        let block = sine(amplitude: 0.3, frames: 4800)
        let writer = Task.detached {
            for i in 0..<2_000 { meter.process(samples: block, sampleRate: 48_000, at: Double(i) * 0.1) }
        }
        var readings = 0
        for i in 0..<20_000 {
            let level = meter.level(at: Double(i) * 0.01)
            #expect(level >= 0 && level <= 1)
            readings += 1
        }
        await writer.value
        #expect(readings == 20_000)
        #expect(meter.level(at: 199.95) > 0.5)
    }

    @Test func speechPlayerEnvelope() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frames = 4800 + 480                       // 110 ms: five full 20 ms windows and a half one
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = [Float](repeating: 0, count: 1920) + sine(amplitude: 0.1, frames: 1920) + sine(amplitude: 0.5, frames: 1440)
        for (i, s) in samples.enumerated() { buffer.floatChannelData![0][i] = s }

        let envelope = SpeechPlayer.envelope(of: buffer)
        #expect(envelope.count == 6)
        #expect(envelope[0] == 0 && envelope[1] == 0)
        #expect(abs(envelope[2] - 0.4713) < 0.01 && abs(envelope[3] - 0.4713) < 0.01)
        #expect(envelope[4] == 1 && envelope[5] == 1)

        let lookup = SpeechPlayer.Envelope(levels: envelope, window: 960, sampleRate: 48_000)
        #expect(lookup.level(atSample: -1) == 0)
        #expect(lookup.level(atSample: 959) == 0)
        #expect(lookup.level(atSample: 2000) > 0.4)
        #expect(lookup.level(atSample: 5000) == 1)
        #expect(lookup.level(atSample: 5760) == 0, "silent once it has played")
    }

    @MainActor @Test func idleSpeechPlayerIsSilent() {
        let player = SpeechPlayer()
        #expect(!player.isPlaying)
        #expect(player.speechLevel == 0)
        player.stop()
        #expect(player.speechLevel == 0)
    }
}
