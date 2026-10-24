import Foundation
import Testing
@testable import CharacterKit

@Suite struct PacerTests {
    private func budget(_ signals: PacingSignals, _ policy: PacingPolicy = .standard) -> RenderBudget {
        RenderPacer.budget(for: signals, policy: policy)
    }

    private func fps(_ n: Int, _ quality: QualityTier) -> RenderBudget {
        RenderBudget(framesPerSecond: n, quality: quality)
    }

    @Test func everyRowOfTheTable() {
        #expect(budget(PacingSignals()) == fps(60, .full))
        #expect(budget(PacingSignals(onBattery: true)) == fps(30, .reduced))
        #expect(budget(PacingSignals(userIdleSeconds: 60)) == fps(30, .reduced))
        #expect(budget(PacingSignals(userIdleSeconds: 59)) == fps(60, .full))
        #expect(budget(PacingSignals(lowPowerMode: true)) == fps(20, .low))
        #expect(budget(PacingSignals(thermal: .fair)) == fps(60, .full))
        #expect(budget(PacingSignals(thermal: .serious)) == fps(20, .low))
        #expect(budget(PacingSignals(thermal: .critical)) == fps(10, .low))
        #expect(budget(PacingSignals(reduceMotion: true)) == fps(0, .full))
        #expect(budget(PacingSignals(characterAtRest: true)) == fps(0, .full))
    }

    @Test(arguments: [
        PacingSignals(occluded: true), PacingSignals(screenLocked: true), PacingSignals(displayAsleep: true),
        PacingSignals(systemSleeping: true), PacingSignals(userIdleSeconds: 300), PacingSignals(explicitlyPaused: true),
    ])
    func stopRowsStopDrawing(signals: PacingSignals) {
        #expect(budget(signals).isStopped)
        var speaking = signals
        speaking.speaking = true
        #expect(budget(speaking).isStopped, "stop rows beat speaking")
    }

    @Test func mostRestrictiveRowWins() {
        #expect(budget(PacingSignals(lowPowerMode: true, onBattery: true)) == fps(20, .low))
        #expect(budget(PacingSignals(thermal: .critical, onBattery: true)) == fps(10, .low))
        #expect(budget(PacingSignals(userIdleSeconds: 120, lowPowerMode: true, thermal: .critical)) == fps(10, .low))
        // a policy whose rows disagree takes the lowest rate and the lowest tier separately
        var policy = PacingPolicy.standard
        policy.relaxed = fps(15, .reduced)
        #expect(budget(PacingSignals(lowPowerMode: true, onBattery: true), policy) == fps(15, .low))
    }

    @Test func speakingLiftsTheRateToItsFloor() {
        #expect(budget(PacingSignals(speaking: true)) == fps(60, .full))
        #expect(budget(PacingSignals(thermal: .critical, speaking: true)) == fps(30, .low))
        #expect(budget(PacingSignals(lowPowerMode: true, onBattery: true, speaking: true)) == fps(30, .low))
        #expect(budget(PacingSignals(characterAtRest: true, speaking: true)) == fps(60, .full), "the level must be read to see it rise")
        #expect(budget(PacingSignals(onBattery: true, characterAtRest: true, speaking: true)) == fps(30, .reduced))
        #expect(budget(PacingSignals(reduceMotion: true, speaking: true)) == fps(0, .full), "a still pose does not talk")
    }

    @Test func stoppedBudgetsKeepThePowerTier() {
        #expect(budget(PacingSignals(thermal: .serious, explicitlyPaused: true)) == fps(0, .low))
        #expect(budget(PacingSignals(occluded: true, onBattery: true)) == fps(0, .reduced))
        #expect(budget(PacingSignals(occluded: true, thermal: .critical, reduceMotion: true)) == fps(0, .full))
    }

    @Test func thresholdsComeFromThePolicy() {
        var policy = PacingPolicy.standard
        policy.stopAfterIdle = 30
        policy.relaxAfterIdle = 10
        policy.speakingFloor = 45
        #expect(budget(PacingSignals(userIdleSeconds: 10), policy) == fps(30, .reduced))
        #expect(budget(PacingSignals(userIdleSeconds: 30), policy).isStopped)
        #expect(budget(PacingSignals(onBattery: true, speaking: true), policy) == fps(45, .reduced))
    }

    @Test func thermalLevelsMirrorProcessInfo() {
        #expect(ThermalLevel(.nominal) == .nominal)
        #expect(ThermalLevel(.fair) == .fair)
        #expect(ThermalLevel(.serious) == .serious)
        #expect(ThermalLevel(.critical) == .critical)
        #expect(ThermalLevel.allCases.sorted() == ThermalLevel.allCases)
    }

    @MainActor @Test func pacerReportsEachChangeOnce() {
        let pacer = RenderPacer()
        var seen: [RenderBudget] = []
        pacer.onBudgetChange = { seen.append($0) }
        #expect(pacer.budget == fps(60, .full))

        pacer.signals.onBattery = true
        pacer.signals.userIdleSeconds = 70          // same budget: no call
        pacer.signals.userIdleSeconds = 80
        pacer.signals.occluded = true
        pacer.signals.occluded = false
        pacer.signals.onBattery = false              // still idle: relaxed
        #expect(seen == [fps(30, .reduced), fps(0, .reduced), fps(30, .reduced)])

        pacer.policy.relaxAfterIdle = 100            // policy changes recompute too
        #expect(seen.last == fps(60, .full))
        #expect(seen.count == 4)
    }

    @MainActor @Test func forcedBudgetOverridesThePolicy() {
        let pacer = RenderPacer(signals: PacingSignals(occluded: true))
        var calls = 0
        pacer.onBudgetChange = { _ in calls += 1 }
        pacer.forcedBudget = fps(20, .low)
        #expect(pacer.budget == fps(20, .low))
        pacer.signals.thermal = .critical            // ignored while forced
        #expect(pacer.budget == fps(20, .low))
        pacer.forcedBudget = nil
        #expect(pacer.budget == fps(0, .low))
        #expect(calls == 2)
    }

    @MainActor @Test func systemSignalsStartAndStopCleanly() {
        let pacer = RenderPacer()
        var signals: SystemSignals? = SystemSignals(pacer: pacer)
        signals?.start()
        #expect(signals?.isRunning == true)
        #expect(pacer.signals.lowPowerMode == ProcessInfo.processInfo.isLowPowerModeEnabled)
        #expect(pacer.signals.thermal == ThermalLevel(ProcessInfo.processInfo.thermalState))
        #expect(pacer.signals.userIdleSeconds >= 0)
        signals?.stop()
        #expect(signals?.isRunning == false)
        signals?.start()
        signals = nil                                 // deinit removes every observer
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }
}
