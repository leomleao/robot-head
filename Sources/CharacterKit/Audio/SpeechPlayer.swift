// Plays a voice and knows how loud it is at every moment. Its level envelope is
// worked out once, before playing, from the same audio it schedules, and is read
// at the sample the player is on, so the jaw moves exactly with what is heard
// rather than a block behind as a tap would.

import AVFAudio
import Synchronization

/// Plays a file or a PCM buffer through its own engine and answers ``speechLevel`` from its position in it.
/// Buddy's voice (ElevenLabs PCM) goes through one; ``AudioLevelMeter`` is for taps on someone else's graph.
@MainActor
public final class SpeechPlayer: SpeechLevelSource {
    /// Seconds of audio per level window.
    public nonisolated static let windowDuration: TimeInterval = 0.02

    /// Whether something is playing now.
    public private(set) var isPlaying = false

    /// Called when what was playing has been heard to its end (not after ``stop()`` or a new
    /// `play`): the cue to set the character back from speaking.
    public var onFinish: (@MainActor () -> Void)?

    /// How loud it plays, 0–1; the level it reports is the audio's own, whatever this is, so a muted
    /// voice still moves the mouth. Default 1.
    public var volume: Float = 1 {
        didSet { player.volume = min(1, max(0, volume)) }
    }

    private var engine: AVAudioEngine?
    // Sendable: `speechLevel` reads its render time from whatever thread polls it.
    private nonisolated let player = AVAudioPlayerNode()
    private nonisolated let current = Mutex<Envelope?>(nil)
    private var generation = 0

    /// A player; the engine starts on the first ``play(buffer:)``.
    public init() {}

    /// Play the audio file at `url`, replacing whatever is playing.
    public func play(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        try file.read(into: buffer)
        try play(buffer: buffer)
    }

    /// Play `buffer` (float PCM, any rate and channel count), replacing whatever is playing.
    public func play(buffer: AVAudioPCMBuffer) throws {
        stop()
        let engine = try prepareEngine(for: buffer.format)
        let envelope = Envelope(levels: Self.envelope(of: buffer), window: Self.windowFrames(at: buffer.format.sampleRate), sampleRate: buffer.format.sampleRate)
        generation += 1
        let playing = generation
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(playing) }
        }
        if !engine.isRunning { try engine.start() }
        current.withLock { $0 = envelope }
        try player.playAudio()
        isPlaying = true
    }

    /// Stop playing; the level drops to 0.
    public func stop() {
        generation += 1
        current.withLock { $0 = nil }
        if engine != nil { player.stop() }
        isPlaying = false
    }

    private func finished(_ playing: Int) {
        guard playing == generation else { return }
        current.withLock { $0 = nil }
        isPlaying = false
        onFinish?()
    }

    private func prepareEngine(for format: AVAudioFormat) throws -> AVAudioEngine {
        let engine = self.engine ?? {
            let engine = AVAudioEngine()
            engine.attach(player)
            self.engine = engine
            return engine
        }()
        // the player plays in the buffer's own format; the mixer converts it for the device
        if engine.outputConnectionPoints(for: player, outputBus: 0).isEmpty || player.outputFormat(forBus: 0) != format {
            try engine.connectNode(player, to: engine.mainMixerNode, format: format)
        }
        return engine
    }

    // MARK: Level

    /// How open the mouth should be for the sample being heard now, 0–1.
    public nonisolated var speechLevel: Float {
        guard let envelope = current.withLock({ $0 }),
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return 0 }
        var position = Double(playerTime.sampleTime)
        // The render time is the start of the last block; move on to now within it, using when
        // that block is heard, so the level is the sample at the speaker, not the one rendered.
        if nodeTime.isHostTimeValid {
            let since = AudioLevelMeter.now - AVAudioTime.seconds(forHostTime: nodeTime.hostTime)
            position += min(0.1, max(-0.1, since)) * playerTime.sampleRate
        }
        return envelope.level(atSample: position / playerTime.sampleRate * envelope.sampleRate)
    }

    /// The level of each ``windowDuration`` of `buffer`, mono-mixed and mapped as ``AudioLevelMeter/level(rms:)``.
    public nonisolated static func envelope(of buffer: AVAudioPCMBuffer, windowDuration: TimeInterval = windowDuration) -> [Float] {
        envelope(of: monoSamples(of: buffer), sampleRate: buffer.format.sampleRate, windowDuration: windowDuration)
    }

    /// The level of each `windowDuration` of mono `samples`; the last window may be shorter.
    public nonisolated static func envelope(of samples: [Float], sampleRate: Double, windowDuration: TimeInterval = windowDuration) -> [Float] {
        let window = windowFrames(at: sampleRate, windowDuration: windowDuration)
        return samples.withUnsafeBufferPointer { all in
            stride(from: 0, to: all.count, by: window).map { lo in
                AudioLevelMeter.level(rms: rms(UnsafeBufferPointer(rebasing: all[lo..<min(all.count, lo + window)])))
            }
        }
    }

    nonisolated static func windowFrames(at sampleRate: Double, windowDuration: TimeInterval = windowDuration) -> Int {
        max(1, Int((sampleRate * windowDuration).rounded()))
    }

    struct Envelope: Sendable {
        var levels: [Float]
        /// Samples per level.
        var window: Int
        var sampleRate: Double

        /// The level of the window holding `sample`; 0 before the start and after the end.
        func level(atSample sample: Double) -> Float {
            let index = Int((sample / Double(window)).rounded(.down))
            return levels.indices.contains(index) ? levels[index] : 0
        }
    }
}
