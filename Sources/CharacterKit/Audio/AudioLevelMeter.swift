// Lip-sync from someone else's audio graph: a tap on any node turns what it
// plays into a 0–1 level, mapped as src/audio.ts maps it, so quiet room noise
// keeps the mouth shut and ordinary speech opens it most of the way; the
// character's own springs smooth it into a jaw's motion.
//
// Taps hand over audio in large blocks (often ~100 ms) after it has rendered, so
// each block is cut into ~1024-sample windows that are played out one after the
// other over the block's duration. Showing only the newest level would step the
// jaw ten times a second. The audio thread writes each window to a ring of
// atomics and the main thread reads the one for "now" without locking.

import AVFAudio
import Synchronization

/// A live speech level from a tap on an `AVAudioNode`, such as Buddy's voice player or a main mixer.
public final class AudioLevelMeter: SpeechLevelSource, Sendable {
    /// Samples per window: about 20 ms at 48 kHz, the analyser size the TS uses.
    public let windowSize: Int
    /// Once the audio it was given has played out, the level falls to 0 after this many seconds.
    public let staleAfter: TimeInterval

    private static let slotCount = 128
    // Each window is a time and a level. A slot is rewritten only every `slotCount` windows, so a
    // reader that sees its time change while reading the level just skips it.
    private let times: InlineArray<128, Atomic<UInt64>>
    private let levels: InlineArray<128, Atomic<UInt32>>
    /// Windows written so far; the newest is at `(written - 1) % slotCount`.
    private let written = Atomic<Int>(0)
    /// When the last window given has played out.
    private let end = Atomic<UInt64>(0)
    private let tap = Mutex<Tap?>(nil)

    private struct Tap {
        weak var node: AVAudioNode?
        var bus: AVAudioNodeBus
    }

    /// A meter cutting audio into `windowSize`-sample windows.
    public init(windowSize: Int = 1024, staleAfter: TimeInterval = 0.15) {
        self.windowSize = max(1, windowSize)
        self.staleAfter = staleAfter
        times = InlineArray { _ in Atomic(0) }
        levels = InlineArray { _ in Atomic(0) }
    }

    deinit { remove() }

    /// How open the mouth should be for an RMS amplitude: a gate under quiet noise, then a curve
    /// that is most of the way open at an ordinary speaking level (src/audio.ts).
    public static func level(rms: Float) -> Float {
        let t = min(1, max(0, (rms - 0.012) / 0.16))
        return pow(t, 0.75)
    }

    /// The current time on the clock ``process(samples:sampleRate:at:)`` and ``level(at:)`` use: host time in seconds.
    public static var now: TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    // MARK: Tapping

    /// Listen to what `node` outputs on `bus`, replacing any tap this meter had. The node keeps playing as before.
    /// Throws if the node refuses the tap (a bus that already has one, say).
    public func install(on node: AVAudioNode, bus: AVAudioNodeBus = 0) throws {
        remove()
        // The throwing tap is refined for Swift but has no overlay yet, so it is called by its raw name.
        try node.__installTap(onBus: bus, bufferSize: AVAudioFrameCount(windowSize), format: nil, error: ()) { [weak self] buffer, when in
            self?.process(buffer: buffer, when: when)
        }
        tap.withLock { $0 = Tap(node: node, bus: bus) }
    }

    /// Stop listening. The level falls to 0 once the audio already given has played out.
    public func remove() {
        guard let old = tap.withLock({ tap in defer { tap = nil }; return tap }) else { return }
        old.node?.removeTap(onBus: old.bus)
    }

    private func process(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let samples = monoSamples(of: buffer)
        guard !samples.isEmpty else { return }
        // A block normally arrives after it has rendered, so its windows play out from now; one
        // that arrives early starts when it is heard.
        let now = Self.now
        let start = when.isHostTimeValid ? max(now, AVAudioTime.seconds(forHostTime: when.hostTime)) : now
        process(samples: samples, sampleRate: buffer.format.sampleRate, at: start)
    }

    // MARK: Levels

    /// Cut mono `samples` into windows and schedule their levels one after the other from `start`
    /// (seconds on ``now``'s clock). Taps call it; tests can call it directly.
    public func process(samples: [Float], sampleRate: Double, at start: TimeInterval) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        // equal windows of about `windowSize`, never more than half the ring
        let count = min(Self.slotCount / 2, max(1, Int((Double(samples.count) / Double(windowSize)).rounded())))
        samples.withUnsafeBufferPointer { all in
            for i in 0..<count {
                let lo = all.count * i / count, hi = all.count * (i + 1) / count
                let level = Self.level(rms: rms(UnsafeBufferPointer(rebasing: all[lo..<hi])))
                let slot = written.load(ordering: .relaxed) % Self.slotCount
                times[slot].store(.max, ordering: .releasing)
                levels[slot].store(level.bitPattern, ordering: .releasing)
                times[slot].store((start + Double(lo) / sampleRate).bitPattern, ordering: .releasing)
                written.add(1, ordering: .releasing)
            }
        }
        end.store((start + Double(samples.count) / sampleRate).bitPattern, ordering: .releasing)
    }

    /// The level at `time` (seconds on ``now``'s clock): the newest window that has started by then,
    /// or 0 once everything given has played out for ``staleAfter``.
    public func level(at time: TimeInterval) -> Float {
        let total = written.load(ordering: .acquiring)
        guard total > 0, time <= Double(bitPattern: end.load(ordering: .acquiring)) + staleAfter else { return 0 }
        // Walk back from the newest: later blocks may already be queued for the future.
        for back in 0..<min(total, Self.slotCount) {
            let slot = (total - 1 - back) % Self.slotCount
            let stamp = times[slot].load(ordering: .acquiring)
            let level = levels[slot].load(ordering: .acquiring)
            guard stamp != .max, times[slot].load(ordering: .acquiring) == stamp else { continue }
            if Double(bitPattern: stamp) <= time { return Float(bitPattern: level) }
        }
        return 0
    }

    /// How open the mouth should be now, 0–1. Lock-free; safe from any thread.
    public var speechLevel: Float { level(at: Self.now) }
}

// MARK: Shared with SpeechPlayer

/// The buffer's channels averaged into one, as a mono analyser hears them.
func monoSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
    guard let data = buffer.floatChannelData else { return [] }
    let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount), stride = buffer.stride
    guard frames > 0, channels > 0 else { return [] }
    var mono = [Float](repeating: 0, count: frames)
    let scale = 1 / Float(channels)
    for c in 0..<channels {
        // interleaved audio keeps every channel in the first pointer, `stride` apart
        let base = buffer.format.isInterleaved ? data[0] + c : data[c]
        for i in 0..<frames { mono[i] += base[i * stride] * scale }
    }
    return mono
}

/// Root mean square of `samples`.
func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for s in samples { sum += s * s }
    return (sum / Float(samples.count)).squareRoot()
}
