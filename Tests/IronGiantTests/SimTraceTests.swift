import CharacterKit
import Foundation
import Testing
@testable import IronGiant

/// Replays each TS golden trace in the Swift sim and compares every frame.
@Suite struct SimTraceTests {
    /* The fixtures are rounded to 1e-7, and every frame agrees to that
       rounding (5e-8 at most). The only libm in play is sin and pow, where V8
       and Darwin could differ in a last bit; 1e-5 leaves room for that
       without letting a real difference through. */
    static let tolerance = 1e-5

    @Test(arguments: SimFixtures.traceNames)
    func replay(_ name: String) throws {
        let trace = try SimFixtures.load(SimTrace.self, "trace-\(name).json")
        let sim = RobotSim(
            seed: trace.seed,
            state: try #require(CharacterState(rawValue: trace.state)),
            expression: trace.expression.map(CharacterExpression.init(rawValue:)),
            eye: SIMD3(trace.eye[0], trace.eye[1], trace.eye[2])
        )
        #expect(trace.rows.count == trace.frames + 1)

        var frame = -1
        var ends: [(id: Int, action: String, outcome: ActionOutcome, frame: Int)] = []
        var worst = (value: 0.0, column: -1, frame: -1)
        func compare(_ row: [Double], _ expected: [Double]) {
            /* the acting flag is exact */
            #expect(row[1] == expected[1], "\(name): acting differs at frame \(frame)")
            let d = maxDeviation(row, expected)
            if d.value > worst.value { worst = (d.value, d.column, frame) }
        }
        compare(sim.row, trace.rows[0])

        var eye = sim.eye
        var dt = trace.dt
        var speed = 1.0
        var next = 0
        for f in 0..<trace.frames {
            frame = f
            while next < trace.events.count && trace.events[next].frame == f {
                let e = trace.events[next]
                next += 1
                switch e.type {
                case "set":
                    if let c = e.eye { eye = SIMD3(c[0], c[1], c[2]) }
                    sim.set(
                        state: try #require(CharacterState(rawValue: e.state ?? "")),
                        expression: e.expression.map(CharacterExpression.init(rawValue:)),
                        eye: eye
                    )
                case "act":
                    let id = try #require(e.id), action = try #require(e.action)
                    sim.act(CharacterAction(rawValue: action), hold: e.hold) { outcome in
                        ends.append((id, action, outcome, frame))
                    }
                case "poke":
                    sim.poke()
                case "pointer":
                    sim.pointer = e.x.map { SIMD2($0, e.y!) }
                case "lookAt":
                    sim.lookAt = e.x.map { SIMD2($0, e.y!) }
                case "mouth":
                    sim.mouth = e.value
                case "speed":
                    speed = try #require(e.value)
                case "dt":
                    dt = try #require(e.value)
                default:
                    Issue.record("unknown event \(e.type)")
                }
            }
            sim.update(dt * speed)
            compare(sim.row, trace.rows[f + 1])
        }

        let column = worst.column >= 0 ? trace.columns[worst.column] : "-"
        print("trace \(name): max deviation \(worst.value) (\(column), frame \(worst.frame))")
        #expect(worst.value <= Self.tolerance, "\(name): \(column) off by \(worst.value) at frame \(worst.frame)")

        /* actions end in the same frame, the same way, in the same order */
        #expect(ends.map(\.id) == trace.actions.map(\.id), "\(name): action ends")
        for (got, want) in zip(ends, trace.actions) {
            #expect(got.action == want.action)
            #expect(got.frame == want.frame, "\(name): action \(want.id) ended in frame \(got.frame), TS \(want.frame)")
            let outcome: ActionOutcome = want.outcome == "interrupted" ? .interrupted : .completed
            #expect(got.outcome == outcome, "\(name): action \(want.id) \(got.outcome), TS \(want.outcome)")
            /* the TS time is the substep's; the Swift completion reports at the end of the frame's call */
            let frameEnd = trace.rows[want.frame + 1][0], frameStart = trace.rows[want.frame][0]
            #expect(want.time >= frameStart - 1e-7 && want.time <= frameEnd + 1e-7)
        }
    }

    @Test func tracesCoverEverything() throws {
        var states = Set<String>(), expressions = Set<String>(), actions = Set<String>()
        for name in SimFixtures.traceNames {
            let trace = try SimFixtures.load(SimTrace.self, "trace-\(name).json")
            states.insert(trace.state)
            if let e = trace.expression { expressions.insert(e) }
            for e in trace.events {
                if e.type == "set", let s = e.state { states.insert(s) }
                if e.type == "set", let x = e.expression { expressions.insert(x) }
                if e.type == "act", let a = e.action { actions.insert(a) }
            }
        }
        #expect(SimFixtures.traceNames.count >= 8)
        #expect(Set(CharacterState.allCases.map(\.rawValue)).isSubset(of: states))
        #expect(Set(CharacterExpression.core.map(\.rawValue)).isSubset(of: expressions))
        #expect(Set(CharacterAction.core.map(\.rawValue)).isSubset(of: actions))
    }
}

// MARK: - Fixtures


// The fixtures scripts/swift/sim-trace.mjs records from the TS sim, read by
// path (the package has no resource bundles).

enum SimFixtures {
    static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/sim")

    static func load<T: Decodable>(_ type: T.Type, _ file: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: directory.appending(path: file)))
    }

    /// The trace files, by name ("trace-<name>.json").
    static var traceNames: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return files.filter { $0.hasPrefix("trace-") && $0.hasSuffix(".json") }
            .map { String($0.dropFirst(6).dropLast(5)) }
            .sorted()
    }
}

/// One scenario: a starting sim, a timeline of inputs by frame, and every frame the TS drew.
struct SimTrace: Decodable {
    struct Event: Decodable {
        let frame: Int
        let type: String
        let state: String?
        let expression: String?
        let eye: [Double]?
        let action: String?
        let id: Int?
        let hold: Double?
        let x: Double?
        let y: Double?
        let value: Double?
    }

    struct ActionEnd: Decodable {
        let id: Int
        let action: String
        let outcome: String
        let frame: Int
        let time: Double
    }

    let name: String
    let seed: Double
    let state: String
    let expression: String?
    let eye: [Double]
    let dt: Double
    let frames: Int
    let events: [Event]
    let actions: [ActionEnd]
    let columns: [String]
    /// rows[0] is the sim as constructed; rows[n] is after frame n − 1.
    let rows: [[Double]]
}

/// The rig's tables and a few of its functions' outputs.
struct RigFixture: Decodable {
    struct Targets: Decodable {
        let eye: [Double]
        let states: [String: [Double]]
        let expressions: [String: [Double]]
    }

    struct Sequence: Decodable {
        let length: Double
        /// [t, neutral with the sequence over it, angry with it over it]
        let samples: [[Sample]]
    }

    enum Sample: Decodable {
        case time(Double)
        case face([Double])

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let t = try? c.decode(Double.self) { self = .time(t) } else { self = .face(try c.decode([Double].self)) }
        }

        var time: Double { if case .time(let t) = self { t } else { .nan } }
        var face: [Double] { if case .face(let f) = self { f } else { [] } }
    }

    struct Springs: Decodable {
        let speed1: [[Double]]
        let speed2: [[Double]]
        let snap: [Double]
    }

    let columns: [String]
    let names: [String]
    let actions: [String]
    let rng: [String: [Double]]
    let expressions: [String: [Double]]
    let stateFace: [String: String]
    let rest: [String: [Double]]
    let targets: Targets
    let sequences: [String: Sequence]
    let springs: Springs
    let mix: [Double]
}

extension FaceRig {
    /// The face in the traces' column order: both eyes, colour, jaw, offsets.
    var row: [Double] {
        (0..<EyeRig.slotCount).map { left[$0] } + (0..<EyeRig.slotCount).map { right[$0] }
            + [color.x, color.y, color.z, jawOpen, jawSmile, yaw, pitch, roll]
    }
}

extension RobotSim {
    /// A trace row: time, whether an action is playing, the pose, the face.
    var row: [Double] {
        [time, isActing ? 1 : 0, pose.yaw, pose.pitch, pose.roll, pose.x, pose.lift] + face.row
    }
}

/// The largest difference between two rows, and where.
func maxDeviation(_ a: [Double], _ b: [Double]) -> (value: Double, column: Int) {
    precondition(a.count == b.count, "rows of \(a.count) and \(b.count)")
    var worst = (value: 0.0, column: -1)
    for i in a.indices {
        let d = abs(a[i] - b[i])
        if !(d <= worst.value) { worst = (d.isNaN ? .infinity : d, i) }
    }
    return worst
}
