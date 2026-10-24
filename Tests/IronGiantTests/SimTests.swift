import CharacterKit
import Testing
@testable import IronGiant

/// Actions and their outcomes, which the traces cover frame by frame; these pin the rules down.
@Suite struct SimTests {
    func sim(_ state: CharacterState = .idle) -> RobotSim {
        RobotSim(seed: 0.25, state: state, expression: nil, eye: FaceRig.white)
    }

    /* steps of 1/120 s, one substep each, until `done` or `seconds` pass; returns the time */
    @discardableResult
    func run(_ s: RobotSim, for seconds: Double, until done: () -> Bool = { false }) -> Double {
        for _ in 0..<Int(seconds * 120) {
            s.update(1.0 / 120)
            if done() { break }
        }
        return s.time
    }

    @Test(arguments: [(nil, 1.6), (0.5, 0.5), (0, 0), (-1, 0)] as [(Double?, Double)])
    func defenseHoldTiming(hold: Double?, red: Double) {
        let s = sim()
        var outcome: ActionOutcome?
        s.act(.defense, hold: hold) { outcome = $0 }
        #expect(s.isActing)
        /* red for the hold, then back to white with the defenseOff sequence, then done */
        if red > 0.05 {
            run(s, for: red - 0.05)
            #expect(s.face.color.y < 150, "still red just before the hold ends")
        }
        let end = run(s, for: 3) { outcome != nil }
        #expect(outcome == .completed)
        #expect(!s.isActing)
        #expect(end >= red + 0.25 - 1e-9 && end <= red + 0.25 + 1.0 / 120 + 1e-9, "ended at \(end)")
        run(s, for: 1.5)
        #expect(s.face.color.y > 200, "white again")
    }

    @Test func unsupportedActionLeavesThePlayingOne() {
        let s = sim()
        var nod: ActionOutcome?
        s.act(.nod, hold: nil) { nod = $0 }
        var dance: ActionOutcome?
        s.act("dance", hold: nil) { dance = $0 }
        #expect(dance == .unsupported)
        #expect(nod == nil && s.isActing)
        run(s, for: 2) { nod != nil }
        #expect(nod == .completed)
    }

    @Test func interruptionOrder() {
        let s = sim()
        var log: [String] = []
        s.act(.nod, hold: nil) { log.append("nod \($0)") }
        run(s, for: 0.3)
        s.act(.shake, hold: nil) { outcome in
            log.append("shake \(outcome)")
        }
        /* the cut-short action hears about it when act returns, with the new one already playing */
        #expect(log == ["nod interrupted"])
        #expect(s.isActing)
        s.act(.defense, hold: 0.2) { log.append("defense \($0)") }
        #expect(log == ["nod interrupted", "shake interrupted"])
        run(s, for: 2) { !s.isActing }
        #expect(log == ["nod interrupted", "shake interrupted", "defense completed"])
    }

    @Test func completionMayActAgain() {
        let s = sim()
        var log: [ActionOutcome] = []
        s.act(.blink, hold: nil) { outcome in
            log.append(outcome)
            s.act(.nod, hold: nil) { log.append($0) }
        }
        run(s, for: 0.5)
        #expect(log == [.completed])
        #expect(s.isActing)
        run(s, for: 2) { !s.isActing }
        #expect(log == [.completed, .completed])
    }

    @Test func everyActionEnds() {
        for action in RobotSim.actions {
            let s = sim(.listening)
            var outcome: ActionOutcome?
            s.act(action, hold: nil) { outcome = $0 }
            run(s, for: 3) { outcome != nil }
            #expect(outcome == .completed, "\(action)")
        }
    }

    @Test func zeroOrBadStepsDoNothing() {
        let s = sim()
        let before = s.row
        s.update(0)
        s.update(-1)
        s.update(.nan)
        s.update(.infinity)
        #expect(s.row == before)
    }

    @Test func seedsAreDeterministic() {
        let a = RobotSim(seed: 0.61, state: .idle, expression: nil, eye: FaceRig.white)
        let b = RobotSim(seed: 0.61, state: .idle, expression: nil, eye: FaceRig.white)
        let c = RobotSim(seed: 0.62, state: .idle, expression: nil, eye: FaceRig.white)
        for _ in 0..<600 {
            a.update(1.0 / 60); b.update(1.0 / 60); c.update(1.0 / 60)
        }
        #expect(a.row == b.row)
        #expect(a.row != c.row)
    }
}
