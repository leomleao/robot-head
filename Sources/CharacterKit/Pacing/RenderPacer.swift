// How often to draw, and how well. The policy is a pure function of what the
// system and the character are doing, so it is tested without a window; the
// pacer holds the current answer and says when it changes. Nothing is drawn
// while nobody can see it, and power and heat trade frames and detail first.

import Foundation

/// The machine's thermal pressure, mirroring `ProcessInfo.ThermalState` so signals stay plain, comparable data.
public enum ThermalLevel: Int, CaseIterable, Comparable, Sendable, Codable {
    case nominal, fair, serious, critical

    /// The level for a `ProcessInfo` thermal state; an unknown future state counts as critical.
    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Everything the pacer weighs. ``SystemSignals`` fills in the system's half; the view fills in
/// the character's (`explicitlyPaused`, `characterAtRest`, `speaking`).
public struct PacingSignals: Sendable, Equatable {
    /// The window is fully covered, minimised, off-screen or on another Space.
    public var occluded = false
    /// The screen is locked, or the session has been switched away from.
    public var screenLocked = false
    /// The displays are asleep.
    public var displayAsleep = false
    /// The system is going to sleep.
    public var systemSleeping = false
    /// Seconds since the user last touched a keyboard, mouse or trackpad.
    public var userIdleSeconds: Double = 0
    /// Seconds since the character last had something to show (a new state, expression or action,
    /// or speech). The idle rows go by whichever of the two is shorter, so a character reacting to
    /// an event, or talking, while the user is away still moves for whoever looks up.
    /// Infinity (the default) leaves it to the user alone.
    public var characterIdleSeconds: Double = .infinity
    /// Low Power Mode is on.
    public var lowPowerMode = false
    public var thermal: ThermalLevel = .nominal
    /// Running on battery rather than on mains power.
    public var onBattery = false
    /// The Reduce Motion accessibility setting.
    public var reduceMotion = false
    /// The app paused the character (`isPaused`, or speed 0).
    public var explicitlyPaused = false
    /// The character reported that nothing is moving (`advance` returned false).
    public var characterAtRest = false
    /// A live speech source is attached, so the level must be read often enough for lip-sync.
    public var speaking = false

    /// Signals for a visible window on a cool, mains-powered, attended machine.
    public init(
        occluded: Bool = false, screenLocked: Bool = false, displayAsleep: Bool = false, systemSleeping: Bool = false,
        userIdleSeconds: Double = 0, characterIdleSeconds: Double = .infinity, lowPowerMode: Bool = false, thermal: ThermalLevel = .nominal, onBattery: Bool = false,
        reduceMotion: Bool = false, explicitlyPaused: Bool = false, characterAtRest: Bool = false, speaking: Bool = false
    ) {
        self.occluded = occluded
        self.screenLocked = screenLocked
        self.displayAsleep = displayAsleep
        self.systemSleeping = systemSleeping
        self.userIdleSeconds = userIdleSeconds
        self.characterIdleSeconds = characterIdleSeconds
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.onBattery = onBattery
        self.reduceMotion = reduceMotion
        self.explicitlyPaused = explicitlyPaused
        self.characterAtRest = characterAtRest
        self.speaking = speaking
    }
}

/// How often to draw and how well. 0 fps means stop drawing and redraw only when something changes.
public struct RenderBudget: Sendable, Equatable {
    /// Frames per second; 0 stops the display link.
    public var framesPerSecond: Int
    public var quality: QualityTier

    /// A budget of `framesPerSecond` at `quality`.
    public init(framesPerSecond: Int, quality: QualityTier) {
        self.framesPerSecond = framesPerSecond
        self.quality = quality
    }

    /// Whether this budget stops continuous drawing.
    public var isStopped: Bool { framesPerSecond <= 0 }
}

/// The thresholds and budgets the pacer applies, one field per row of the policy table.
public struct PacingPolicy: Sendable, Equatable {
    /// Idle this long and drawing stops.
    public var stopAfterIdle: TimeInterval
    /// Idle this long and the character drops to ``relaxed``.
    public var relaxAfterIdle: TimeInterval
    /// Nothing is holding it back.
    public var full: RenderBudget
    /// On battery, or the user idle for ``relaxAfterIdle``.
    public var relaxed: RenderBudget
    /// Thermal pressure serious, or Low Power Mode.
    public var constrained: RenderBudget
    /// Thermal pressure critical.
    public var critical: RenderBudget
    /// While speaking, frames never drop below this, so lip-sync reads (unless drawing has stopped).
    public var speakingFloor: Int

    /// A policy with every field given.
    public init(
        stopAfterIdle: TimeInterval, relaxAfterIdle: TimeInterval, full: RenderBudget, relaxed: RenderBudget,
        constrained: RenderBudget, critical: RenderBudget, speakingFloor: Int
    ) {
        self.stopAfterIdle = stopAfterIdle
        self.relaxAfterIdle = relaxAfterIdle
        self.full = full
        self.relaxed = relaxed
        self.constrained = constrained
        self.critical = critical
        self.speakingFloor = speakingFloor
    }

    /// The default table: 60 fps full; 30 reduced on battery or after a minute idle; 20 low when
    /// hot or in Low Power Mode; 10 low when critical; stop after five minutes idle.
    public static let standard = PacingPolicy(
        stopAfterIdle: 300,
        relaxAfterIdle: 60,
        full: RenderBudget(framesPerSecond: 60, quality: .full),
        relaxed: RenderBudget(framesPerSecond: 30, quality: .reduced),
        constrained: RenderBudget(framesPerSecond: 20, quality: .low),
        critical: RenderBudget(framesPerSecond: 10, quality: .low),
        speakingFloor: 30
    )
}

/// Holds the current ``RenderBudget`` and recomputes it whenever the signals or the policy change.
@MainActor
public final class RenderPacer {
    /// The table the budget is computed from.
    public var policy: PacingPolicy { didSet { recompute() } }
    /// What the system and the character are doing now.
    public var signals: PacingSignals {
        didSet {
            if signals != oldValue { onSignalsChange?(signals) }
            recompute()
        }
    }
    /// A budget that overrides the policy, whatever the signals say (the playground compares tiers with it); nil follows the policy.
    public var forcedBudget: RenderBudget? { didSet { recompute() } }
    /// The budget in force.
    public private(set) var budget: RenderBudget
    /// Called with the new budget each time it changes, and only then.
    public var onBudgetChange: (@MainActor (RenderBudget) -> Void)?
    /// Called with the new signals each time they change, whether or not the budget does (a view
    /// uncovered while stopped still owes a frame).
    public var onSignalsChange: (@MainActor (PacingSignals) -> Void)?

    /// A pacer applying `policy` to `signals`.
    public init(policy: PacingPolicy = .standard, signals: PacingSignals = PacingSignals()) {
        self.policy = policy
        self.signals = signals
        self.budget = Self.budget(for: signals, policy: policy)
    }

    private func recompute() {
        let next = forcedBudget ?? Self.budget(for: signals, policy: policy)
        guard next != budget else { return }
        budget = next
        onBudgetChange?(next)
    }

    /// The budget `policy` gives for `signals`.
    ///
    /// Power and heat pick the most restrictive of their rows. Reduce Motion shows a still pose, drawn once per change
    /// at full quality. Speaking lifts the rate to ``PacingPolicy/speakingFloor``, even when the character says it is
    /// at rest, because the level must be read to see it rise. Nobody watching (occluded, locked, displays or system
    /// asleep, idle too long) or a paused character stops drawing whatever else applies; a stopped budget keeps the
    /// quality power allows, so redraws on change don't switch detail back and forth.
    public nonisolated static func budget(for signals: PacingSignals, policy: PacingPolicy) -> RenderBudget {
        // nothing happening means neither the user nor the character did anything
        let idle = min(signals.userIdleSeconds, signals.characterIdleSeconds)
        var rows = [policy.full]
        if signals.thermal >= .critical { rows.append(policy.critical) }
        if signals.thermal >= .serious || signals.lowPowerMode { rows.append(policy.constrained) }
        if signals.onBattery || idle >= policy.relaxAfterIdle { rows.append(policy.relaxed) }
        var budget = RenderBudget(
            framesPerSecond: rows.map(\.framesPerSecond).min()!,
            quality: rows.map(\.quality).min()!
        )

        if signals.reduceMotion {
            budget = RenderBudget(framesPerSecond: 0, quality: .full)
        } else if signals.speaking {
            budget.framesPerSecond = max(budget.framesPerSecond, policy.speakingFloor)
        } else if signals.characterAtRest {
            budget.framesPerSecond = 0
        }

        let unseen = signals.occluded || signals.screenLocked || signals.displayAsleep || signals.systemSleeping
            || idle >= policy.stopAfterIdle
        if unseen || signals.explicitlyPaused { budget.framesPerSecond = 0 }
        return budget
    }
}
