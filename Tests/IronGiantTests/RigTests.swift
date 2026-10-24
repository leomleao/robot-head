import CharacterKit
import Foundation
import Testing
@testable import IronGiant

/// The rig's tables and functions against the values the TS produces (Fixtures/sim/rig.json).
@Suite struct RigTests {
    let rig: RigFixture

    init() throws {
        rig = try SimFixtures.load(RigFixture.self, "rig.json")
    }

    /* rig.json is rounded to 1e-7 */
    static let tolerance = 1e-7

    func expectClose(_ got: [Double], _ want: [Double], _ what: String, tolerance: Double = Self.tolerance) {
        let d = maxDeviation(got, want)
        #expect(d.value <= tolerance, "\(what): \(d.column >= 0 ? rig.columns[d.column] : "-") off by \(d.value)")
    }

    @Test func expressionTableEqualsTS() {
        #expect(FaceRig.expressionNames.map(\.rawValue) == rig.names)
        #expect(FaceRig.expressions.count == 17)
        for name in FaceRig.expressionNames {
            expectClose(FaceRig.expressions[name]!.row, rig.expressions[name.rawValue]!, name.rawValue)
        }
    }

    @Test func stateFacesAndRestPoses() {
        for state in CharacterState.allCases {
            #expect(stateFace[state]?.rawValue == rig.stateFace[state.rawValue])
            let p = restPose[state]!
            #expect([p.yaw, p.pitch, p.roll, p.x, p.lift] == rig.rest[state.rawValue]!)
        }
    }

    @Test func actionsEqualTS() {
        #expect(RobotSim.actions.map(\.rawValue) == rig.actions)
    }

    @Test func targetFacesEqualTS() {
        let eye = SIMD3(rig.targets.eye[0], rig.targets.eye[1], rig.targets.eye[2])
        for state in CharacterState.allCases {
            expectClose(targetFace(state: state, expression: nil, eye: eye).row, rig.targets.states[state.rawValue]!, state.rawValue)
        }
        for name in FaceRig.expressionNames {
            expectClose(targetFace(state: .idle, expression: name, eye: eye).row, rig.targets.expressions[name.rawValue]!, name.rawValue)
        }
    }

    @Test func eyeColourReplacedExceptRedFaces() {
        let eye = SIMD3<Double>(10, 200, 120)
        let red: Set<CharacterExpression> = [.angry, .attack, .defense]
        for name in FaceRig.expressionNames {
            let f = targetFace(state: .idle, expression: name, eye: eye)
            if red.contains(name) {
                #expect(f.color == FaceRig.expressions[name]!.color && f.color != eye, "\(name)")
                #expect(name.isRed)
            } else {
                #expect(f.color == eye, "\(name)")
                #expect(!name.isRed)
            }
        }
    }

    @Test func unknownExpressionIsTheStatesFace() {
        let eye = FaceRig.white
        for state in CharacterState.allCases {
            #expect(targetFace(state: state, expression: "grumpy", eye: eye) == targetFace(state: state, expression: nil, eye: eye))
        }
        let sim = RobotSim(seed: 0.3, state: .working, expression: "grumpy", eye: eye)
        #expect(sim.expression == nil)
        sim.set(state: .happy, expression: "nope", eye: eye)
        #expect(sim.expression == nil)
        sim.set(state: .happy, expression: .sad, eye: eye)
        #expect(sim.expression == .sad)
    }

    @Test func sequenceLengths() {
        let lengths: [SequenceName: Double] = [.blink: 0.2, .defenseOn: 0.42, .defenseOff: 0.25, .wake: 0.9]
        for name in SequenceName.allCases {
            #expect(name.sequence.length == lengths[name])
            #expect(name.sequence.length == rig.sequences["\(name)"]!.length)
        }
    }

    @Test func sequencesEqualTS() {
        for name in SequenceName.allCases {
            let fixture = rig.sequences["\(name)"]!
            #expect(!fixture.samples.isEmpty)
            for sample in fixture.samples {
                let t = sample[0].time
                var a = FaceRig.expressions[.neutral]!
                name.sequence.apply(at: t, to: &a)
                expectClose(a.row, sample[1].face, "\(name) over neutral at \(t)")
                var b = FaceRig.expressions[.angry]!
                name.sequence.apply(at: t, to: &b)
                expectClose(b.row, sample[2].face, "\(name) over angry at \(t)")
            }
        }
    }

    @Test func springsEqualTS() {
        for (speed, want) in [(1.0, rig.springs.speed1), (2.0, rig.springs.speed2)] {
            var s = FaceSprings(FaceRig.expressions[.neutral]!)
            var got: [[Double]] = []
            for i in 1...360 {
                s.step(toward: FaceRig.expressions[.defense]!, dt: 1.0 / 120, speed: speed)
                if i % 10 == 0 { got.append(s.face.row) }
            }
            #expect(got.count == want.count)
            for (i, (g, w)) in zip(got, want).enumerated() {
                expectClose(g, w, "speed \(speed), sample \(i)")
            }
        }
        var s = FaceSprings(FaceRig.expressions[.neutral]!)
        s.step(toward: FaceRig.expressions[.angry]!, dt: 0.05)
        s.snap(FaceRig.expressions[.sad]!)
        expectClose(s.face.row, rig.springs.snap, "snap")
    }

    @Test func springsConvergeAndStayBounded() {
        for (from, to) in [(CharacterExpression.neutral, CharacterExpression.defense), (.asleep, .joyful), (.attack, .sheepish)] {
            let a = FaceRig.expressions[from]!, b = FaceRig.expressions[to]!
            var s = FaceSprings(a)
            for _ in 0..<(120 * 8) {
                s.step(toward: b, dt: 1.0 / 120)
                /* never far outside the span between start and target: a little overshoot at most */
                for (i, v) in s.face.row.enumerated() {
                    let lo = min(a.row[i], b.row[i]), hi = max(a.row[i], b.row[i])
                    let slack = 0.2 * max(hi - lo, 1e-3) + 1e-4
                    #expect(v >= lo - slack && v <= hi + slack, "\(from)→\(to): \(rig.columns[i]) = \(v)")
                }
            }
            expectClose(s.face.row, b.row, "\(from)→\(to) settled", tolerance: 1e-3)
        }
        /* the head's spring rings down too, after a kick */
        var spring = Spring()
        spring.v = 5
        var peak = 0.0
        for _ in 0..<(120 * 10) {
            spring.step(0.3, dt: 1.0 / 120, freq: 0.9, damping: 0.75)
            peak = max(peak, abs(spring.x))
        }
        #expect(peak < 2)
        #expect(abs(spring.x - 0.3) < 1e-4 && abs(spring.v) < 1e-3)
    }

    @Test func mixEqualsTS() {
        expectClose(mixFace(FaceRig.expressions[.neutral]!, FaceRig.expressions[.angry]!, 0.3).row, rig.mix, "mix")
    }

    @Test func rngEqualsTS() throws {
        #expect(rig.rng.count >= 3)
        for (seed, draws) in rig.rng {
            var r = Mulberry32(seed: try #require(Double(seed)))
            /* exact: the draws are k / 2³², which JSON carries without loss */
            #expect((0..<draws.count).map { _ in r.next() } == draws, "seed \(seed)")
        }
    }
}
