// The readouts: how often the view really drew, what each frame cost, what the
// pacer decided and why, and what the whole process spends on the CPU. Frame
// rates come from the view's frame counter rather than the display link's
// preferred rate, so a stopped or throttled view shows as such.

import CharacterKit
import Darwin
import QuartzCore

/// The process's user + system CPU time so far, in seconds.
func processCPUTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

/// One second's worth of readouts.
struct LiveStats {
    var fps = 0.0
    /// Moving averages of the view's frames, in milliseconds.
    var cpuMs = 0.0
    var gpuMs = 0.0
    /// The process's CPU time over wall time, in percent of one core.
    var cpuPercent = 0.0
    var budget = RenderBudget(framesPerSecond: 0, quality: .full)
    var isForced = false
    var signals = PacingSignals()

    /// The signals that hold the budget back, in a word each.
    var activeSignals: [String] {
        var out: [String] = []
        if signals.occluded { out.append("occluded") }
        if signals.screenLocked { out.append("locked") }
        if signals.displayAsleep { out.append("display asleep") }
        if signals.systemSleeping { out.append("sleeping") }
        if signals.userIdleSeconds >= 5 { out.append("user idle \(Int(signals.userIdleSeconds)) s") }
        if signals.lowPowerMode { out.append("low power") }
        if signals.thermal != .nominal { out.append("thermal \(signals.thermal)") }
        if signals.onBattery { out.append("battery") }
        if signals.reduceMotion { out.append("reduce motion") }
        if signals.explicitlyPaused { out.append("paused") }
        if signals.characterAtRest { out.append("at rest") }
        if signals.speaking { out.append("speaking") }
        return out
    }
}

/// Turns counters into rates between one sample and the next.
@MainActor
final class StatsSampler {
    private var frames = 0
    private var cpu = processCPUTime()
    private var wall = CACurrentMediaTime()

    /// Start measuring afresh, from a view's current frame count.
    func restart(frames: Int) {
        self.frames = frames
        cpu = processCPUTime()
        wall = CACurrentMediaTime()
    }

    func sample(_ view: CharacterView) -> LiveStats {
        let now = CACurrentMediaTime(), cpuNow = processCPUTime(), framesNow = view.stats.frames
        let elapsed = max(1e-3, now - wall)
        let stats = LiveStats(
            fps: Double(framesNow - frames) / elapsed,
            cpuMs: view.stats.cpuTime * 1000,
            gpuMs: view.stats.gpuTime * 1000,
            cpuPercent: (cpuNow - cpu) / elapsed * 100,
            budget: view.pacer.budget,
            isForced: view.pacer.forcedBudget != nil,
            signals: view.pacer.signals
        )
        frames = framesNow
        cpu = cpuNow
        wall = now
        return stats
    }
}
