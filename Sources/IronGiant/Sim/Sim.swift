// The robot's life between frames: the head's pose chases targets on
// heavy springs, the face eases toward the expression it should wear, and
// blinks and glances come and go on their own.
//
// A port of src/robot/sim.ts, step for step: the same constants, the same
// branches, the same order of random draws, 120 Hz substeps. Golden traces
// recorded from the TS (scripts/swift/sim-trace.mjs) hold it to that.
//
// What IronGiantCharacter uses (all internal):
//   RobotSim(seed:state:expression:eye:)       eye is sRGB 0–255
//   sim.set(state:expression:eye:)             an expression outside the 17 wears the state's face
//   sim.pointer, sim.lookAt: SIMD2<Double>?    points from between the eyes at rest, y down
//   sim.mouth: Double?                         an outside jaw level, 0–1; nil for the sim's own talking
//   sim.act(_:hold:completion:)                hold in seconds (defense; nil = 1.6)
//   sim.poke(), sim.update(_ dt:)              dt already multiplied by speed, as RobotHead.tsx does
//   sim.pose: RobotPose, sim.face: FaceRig, sim.isActing
//   targetFace(state:expression:eye:)          the still face; restPose[state] the still pose
//   stateFace[state], RobotSim.actions
//
// Actions report how they ended through `completion`, which the TS does with a
// promise. It is called after the sim call that ended the action returns (at the
// end of `act` for the action it cut short, at the end of `update` for one that
// played out), so it may safely call back into the sim. An action the robot
// doesn't know completes with `.unsupported` at once and leaves the one playing.

import CharacterKit
import Foundation

struct Spring {
    var x = 0.0
    var v = 0.0

    mutating func step(_ target: Double, dt: Double, freq: Double, damping: Double) {
        let w = freq * Double.pi * 2
        v += (w * w * (target - x) - 2 * damping * w * v) * dt
        x += v * dt
    }
}

/// mulberry32, bit for bit as the TS writes it with `Math.imul` and `>>> 0`.
struct Mulberry32 {
    private var a: UInt32

    init(seed: Double) {
        let a = Self.toUInt32((seed * 4294967295).rounded(.down))
        self.a = a == 0 ? 1 : a
    }

    mutating func next() -> Double {
        a = a &+ 0x6d2b79f5
        var t = a
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4294967296
    }

    /* JS ToUint32: the integer modulo 2³², and 0 for what isn't finite */
    private static func toUInt32(_ x: Double) -> UInt32 {
        guard x.isFinite else { return 0 }
        let m = x.rounded(.towardZero).truncatingRemainder(dividingBy: 4294967296)
        return UInt32(m < 0 ? m + 4294967296 : m)
    }
}

private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

/* a smooth hump over [a, b]: zero, with zero speed, at both ends */
private func bump(_ k: Double, _ a: Double, _ b: Double) -> Double {
    if k <= a || k >= b { return 0 }
    let s = sin((Double.pi * (k - a)) / (b - a))
    return s * s
}

/* a head shake over k in 0…1: `turns` slow swings under an envelope that eases in and out */
private func shakeCurve(_ k: Double, _ turns: Double) -> Double {
    if k <= 0 || k >= 1 { return 0 }
    let env = pow(sin(Double.pi * k), 1.5)
    return sin(2 * Double.pi * turns * k) * env
}

/*
 * The jaw's own life: a queue of moves, each a target opening held for a
 * while, chased by a quick spring so the jaw snaps like a hinge rather
 * than floating. Speech is short phrases of one- and two-syllable words
 * with pauses between ("I fix." "You stay. I go."); a hum is a small drop
 * and close; a laugh is a quick run of wide opens.
 */
private struct Jaw {
    private var queue: [(open: Double, seconds: Double)] = []
    private var hold = 0.0
    private var target = 0.0
    var spring = Spring()

    var busy: Bool { !queue.isEmpty || hold > 0 }

    mutating func clear() {
        queue.removeAll()
        hold = 0
        target = 0
    }

    mutating func push(_ open: Double, _ seconds: Double) {
        queue.append((open, seconds))
    }

    mutating func phrase(_ rand: inout Mulberry32) {
        let words = 1 + Int((rand.next() * 3).rounded(.down))
        for _ in 0..<words {
            let syllables = rand.next() < 0.65 ? 1 : 2
            for _ in 0..<syllables {
                push(0.45 + rand.next() * 0.45, 0.1 + rand.next() * 0.1)
                push(0.05 + rand.next() * 0.08, 0.05 + rand.next() * 0.05)
            }
            push(0, 0.16 + rand.next() * 0.22)
        }
        push(0, 0.6 + rand.next() * 0.9)
    }

    mutating func hum(_ rand: inout Mulberry32) {
        push(0.16 + rand.next() * 0.08, 0.22)
        push(0, 0.4)
    }

    mutating func laugh(_ rand: inout Mulberry32) {
        let n = 3 + Int((rand.next() * 2).rounded(.down))
        for _ in 0..<n {
            push(0.55 + rand.next() * 0.25, 0.09)
            push(0.15, 0.07)
        }
        push(0, 0.3)
    }

    mutating func step(_ dt: Double) {
        hold -= dt
        while hold <= 0 && !queue.isEmpty {
            let (open, secs) = queue.removeFirst()
            target = open
            hold += secs
        }
        if hold <= 0 && queue.isEmpty {
            hold = 0
            target = 0
        }
        spring.step(target, dt: dt, freq: 7, damping: 0.75)
    }
}

/// The face each state wears when no expression is given.
let stateFace: [CharacterState: CharacterExpression] = [
    .idle: .neutral,
    .thinking: .curious,
    .searching: .suspicious,
    .listening: .neutral,
    .speaking: .neutral,
    .working: .content,
    .happy: .happy,
    .error: .sheepish,
    .sleeping: .asleep,
]

/* an expression the rig doesn't have counts as none, as RobotHead.tsx drops it */
private func known(_ expression: CharacterExpression?) -> CharacterExpression? {
    guard let e = expression, FaceRig.expressions[e] != nil else { return nil }
    return e
}

private func face(for state: CharacterState, _ expression: CharacterExpression?) -> CharacterExpression {
    known(expression) ?? stateFace[state]!
}

/// The face to aim for: the expression, in the eye colour unless the colour is the point.
func targetFace(state: CharacterState, expression: CharacterExpression?, eye: SIMD3<Double>) -> FaceRig {
    let name = face(for: state, expression)
    var f = FaceRig.expressions[name]!
    if !name.isRed { f.color = eye }
    return f
}

final class RobotSim {
    /// The actions the robot knows (the TS `ROBOT_ACTIONS`).
    static let actions: [CharacterAction] = CharacterAction.core

    private(set) var state: CharacterState
    /// Always one of the 17, or nil.
    private(set) var expression: CharacterExpression?
    private(set) var eye: SIMD3<Double>
    private(set) var time = 0.0
    private(set) var pose = RobotPose()
    /// The pointer, relative to between the eyes at rest in points (y down), or nil.
    var pointer: SIMD2<Double>?
    /// Something to look at instead, in the same terms, or nil.
    var lookAt: SIMD2<Double>?
    /// A level from outside (a fixed level, or audio) that drives the jaw, 0–1, or nil.
    var mouth: Double?
    private(set) var springs: FaceSprings
    /// The face drawn this frame: the springs' face with any scripted change laid over it.
    private(set) var face: FaceRig

    /// Whether an action is playing.
    var isActing: Bool { action != nil }

    private var target: FaceRig
    private var yaw = Spring()
    private var pitch = Spring()
    private var roll = Spring()
    /* a bounce: a hop of the head that rings down */
    private var bounce = Spring()
    private var random: Mulberry32
    private var glance = (yaw: 0.0, pitch: 0.0, gx: 0.0, gy: 0.0)
    private var nextGlance = 0.8
    private var nextBlink = 2.0
    /* the scripted change of face playing now, and how far into it */
    private var seq: (name: SequenceName, t: Double)?
    private var surprise = -1.0
    private var jaw = Jaw()
    private var nextMumble = 6.0
    private var mouthLevel = Spring()
    /* seconds in the current state */
    private var since = 0.0
    /* which way the head leans while thinking, and when it next changes its mind */
    private var side = 1.0
    private var nextSide = 4.0
    /* now and then, idle, the head cocks to one side for a moment: "Hmm?" */
    private var nextTilt = 9.0
    private var tiltUntil = -1.0
    /* the action playing now */
    private var action: (name: CharacterAction, t: Double, length: Double, hold: Double, done: (ActionOutcome) -> Void)?
    /* how the actions ended during the current call, reported when it returns */
    private var ended: [() -> Void] = []
    /* a face an action wears for a while, over the expression */
    private var override: CharacterExpression?
    /* the face worn on the last step, to notice changes */
    private var wearing: CharacterExpression

    init(seed: Double, state: CharacterState, expression: CharacterExpression?, eye: SIMD3<Double>) {
        let expression = known(expression)
        random = Mulberry32(seed: seed)
        self.state = state
        self.expression = expression
        self.eye = eye
        target = targetFace(state: state, expression: expression, eye: eye)
        springs = FaceSprings(target)
        face = target
        wearing = expression ?? stateFace[state]!
        nextBlink = 1 + random.next() * 3
        nextMumble = state == .speaking ? 0.3 : 3 + random.next() * 4
        side = random.next() < 0.5 ? 1 : -1
        nextTilt = 6 + random.next() * 8
        let rest = restPose[state]!
        yaw.x = rest.yaw; pitch.x = rest.pitch; roll.x = rest.roll
    }

    func set(state: CharacterState, expression: CharacterExpression?, eye: SIMD3<Double>) {
        if state != self.state {
            jaw.clear()
            since = 0
            nextMumble = time + (state == .speaking ? 0.15 : 2 + random.next() * 4)
            /* happy arrives with a hop */
            if state == .happy { bounce.v += 0.9 }
        }
        self.state = state
        self.expression = known(expression)
        self.eye = eye
    }

    /// Play a scripted change of face over whatever the face is doing.
    func play(_ name: SequenceName) {
        seq = (name, 0)
    }

    /* the face to wear now: an action's, the expression, or the state's */
    private func current() -> CharacterExpression {
        override ?? expression ?? stateFace[state]!
    }

    /* when the face changes: the eyes turn red and back by the film's steps, and wake from a seam */
    private func changed(_ was: CharacterExpression, _ now: CharacterExpression) {
        /* the iris faces (angry, defense) come and go by the film's steps; attack's pink just eases in */
        func iris(_ n: CharacterExpression) -> Bool { n == .angry || n == .defense }
        if iris(now) && !was.isRed { play(.defenseOn) }
        else if iris(was) && !now.isRed { play(.defenseOff) }
        else if was == .asleep && now != .asleep { play(.wake) }
    }

    /// Do something once, over whatever the robot is doing. A new action cuts
    /// the one playing short (`.interrupted`); one that plays out is `.completed`.
    func act(_ name: CharacterAction, hold: Double? = nil, completion: @escaping (ActionOutcome) -> Void) {
        guard Self.actions.contains(name) else {
            completion(.unsupported)
            return
        }
        finish(.interrupted)
        let hold = max(0, hold ?? 1.6)
        var length = 1.0
        switch name {
        case .blink:
            play(.blink)
            length = FaceSequence.blink.length
        case .nod:
            length = 1.15
        case .shake:
            length = 1.5
        case .hmm:
            jaw.clear()
            jaw.hum(&random)
            length = 1.6
        case .laugh:
            jaw.clear()
            jaw.laugh(&random)
            bounce.v += 0.5
            length = 1
        case .surprise:
            surprise = 0
            if seq == nil { play(.blink) }
            length = 0.9
        case .wake:
            play(.wake)
            length = FaceSequence.wake.length
        case .defense:
            override = .defense
            length = hold + FaceSequence.defenseOff.length
        default:
            break
        }
        action = (name, 0, length, hold, completion)
        report()
    }

    /* end the action playing, if any */
    private func finish(_ outcome: ActionOutcome) {
        guard let a = action else { return }
        action = nil
        if a.name == .defense { override = nil }
        ended.append { a.done(outcome) }
    }

    private func report() {
        let calls = ended
        ended.removeAll()
        for call in calls { call() }
    }

    /// A click: a blink, a flash of surprise, a small hop and a settling nod.
    func poke() {
        if seq == nil { play(.blink) }
        surprise = 0
        bounce.v += 0.5
        pitch.v -= 0.6
    }

    func update(_ dt: Double) {
        /* (an infinite step would never end; the TS hangs on one) */
        if !(dt > 0) || !dt.isFinite { return }
        let steps = max(1, Int((dt / (1.0 / 120)).rounded(.up)))
        for _ in 0..<steps { step(dt / Double(steps)) }
        report()
    }

    private func step(_ dt: Double) {
        time += dt
        since += dt
        let t = time

        if t > nextGlance {
            let yaw = (random.next() - 0.5) * 0.5
            let pitch = (random.next() - 0.5) * 0.16
            let gx = (random.next() - 0.5) * 1.2
            let gy = (random.next() - 0.5) * 0.5
            glance = (yaw, pitch, gx, gy)
            nextGlance = t + 2 + random.next() * 3.5
        }

        /* what this state does with the head, and with the eyes inside it; heavy throughout */
        var yaw = 0.0, pitch = 0.0, roll = 0.0, gx = 0.0, gy = 0.0, lift = 0.0
        var freq = 0.9, damping = 0.75
        /* error's head shake, shaped like the action's and laid on top the same way */
        var errShake = 0.0
        /* whether the head turns to the pointer in this state */
        var follows = true
        switch state {
        case .idle:
            yaw = glance.yaw
            pitch = glance.pitch
            roll = -glance.yaw * 0.12
            gx = glance.gx
            gy = glance.gy
            if t > nextTilt {
                tiltUntil = t + 1.4 + random.next()
                nextTilt = t + 8 + random.next() * 9
            }
            if t < tiltUntil { roll += 0.16 * side }
        case .thinking:
            /* looking up and to one side, then the other, "Souls don't die" */
            if t > nextSide {
                side = -side
                nextSide = t + 3.5 + random.next() * 2.5
            }
            yaw = 0.22 * side + sin(t * 0.7) * 0.03
            pitch = 0.16 + sin(t * 0.9) * 0.02
            roll = -0.1 * side
            gx = 0.4 * side
            gy = -0.6
            freq = 0.7
            follows = false
        case .searching:
            /* a slow sweep, the eyes leading the head */
            let ph = t * 0.85
            yaw = sin(ph) * 0.5
            pitch = 0.03 + sin(ph * 2) * 0.03
            roll = sin(ph) * -0.05
            gx = clamp(sin(ph + 0.7) * 1.1, -1, 1)
            freq = 1.1
            follows = false
        case .listening:
            /* head cocked toward whoever is talking; the nods come with the mm-hmms */
            yaw = -0.12
            pitch = 0.03
            roll = 0.15
            gx = -0.3
        case .speaking:
            yaw = sin(t * 0.6) * 0.08
            roll = sin(t * 0.45) * 0.04
            pitch = 0.02
        case .working:
            /* eyes down on the work, careful, a steady little bob */
            yaw = sin(t * 0.5) * 0.06
            pitch = -0.18
            roll = sin(t * 0.35) * 0.03
            gy = 0.5
            lift = abs(sin(t * 3.1)) * 0.008
            follows = false
        case .happy:
            yaw = glance.yaw * 0.6
            roll = sin(t * 1.6) * 0.07
            pitch = 0.04
            /* now and then another little hop */
            if since > 1.2 && random.next() < dt * 0.25 { bounce.v += 0.45 }
        case .error:
            /* a slow shake of the head every few seconds, and a droop between */
            let c = (since + 0.6).truncatingRemainder(dividingBy: 3.6) / 1.5
            errShake = c < 1 ? shakeCurve(c, 1.5) * 0.15 : 0
            pitch = -0.12
            roll = -0.05
            gy = 0.4
            freq = 1.2
            follows = false
        case .sleeping:
            /* drooped, breathing slowly */
            pitch = -0.3
            roll = 0.1
            yaw = 0.05
            lift = sin(t * 0.9) * 0.012
            freq = 0.4
            damping = 0.9
            follows = false
        }

        /* the action playing: its own motion on top of the state's */
        var ay = 0.0, ap = 0.0, ar = 0.0, agy = 0.0
        if var a = action {
            a.t += dt
            action = a
            let k = a.t / a.length
            switch a.name {
            case .nod:
                /* "Mm-hmm": two easy dips, the second smaller, the head settling after each */
                ap = -(bump(k, 0, 0.52) + 0.55 * bump(k, 0.46, 0.96)) * 0.16
            case .shake:
                /* "No": a slow, heavy swing side to side, the head rolling a little after it */
                ay = shakeCurve(k, 1.5) * 0.2
                ar = -shakeCurve(k - 0.04, 1.5) * 0.04
                ap = -bump(k, 0, 1) * 0.04
            case .hmm:
                /* a slow cock of the head, held, and back */
                ar = 0.18 * side * pow(bump(k, 0, 1), 0.5)
                agy = -0.4
            default:
                break
            }
            if a.name == .defense && a.t >= a.hold { override = nil }
            if a.t >= a.length { finish(.completed) }
        }
        let wearing = current()
        if wearing != self.wearing {
            changed(self.wearing, wearing)
            self.wearing = wearing
        }

        /* something to look at overrides the state's glances, the pointer only where the state allows */
        let look = state == .sleeping ? nil : lookAt ?? (follows ? pointer : nil)
        if let look {
            /* the eyes lead, the head follows: heavy */
            gx = clamp(look.x / 160, -1, 1)
            gy = clamp(look.y / 200, -1, 1)
            yaw = clamp(look.x / 320, -1, 1) * 0.5
            pitch = -clamp(look.y / 320, -1, 1) * 0.26
            roll = -yaw * 0.1 + (state == .listening ? 0.12 : 0)
        }
        self.yaw.step(yaw, dt: dt, freq: freq, damping: damping)
        self.pitch.step(pitch, dt: dt, freq: freq, damping: damping)
        self.roll.step(roll, dt: dt, freq: freq * 0.9, damping: damping)
        gy += agy
        bounce.step(0, dt: dt, freq: 1.7, damping: 0.32)

        /* the face */
        target = targetFace(state: state, expression: current(), eye: eye)
        target.left.gazeX += gx; target.right.gazeX += gx
        target.left.gazeY += gy; target.right.gazeY += gy
        if surprise >= 0 {
            surprise += dt
            let k = sin(clamp(surprise / 0.9, 0, 1) * Double.pi)
            func widen(_ e: inout EyeRig) {
                e.size += 0.12 * k
                e.glow += 0.2 * k
                e.lidTop *= 1 - k
            }
            widen(&target.left)
            widen(&target.right)
            target.jawOpen += 0.3 * k
            if surprise > 0.9 { surprise = -1 }
        }
        springs.step(toward: target, dt: dt)

        /* the jaw: talk while speaking, a hum or an mm-hmm now and then, a laugh when happy */
        if mouth == nil && t > nextMumble && !jaw.busy {
            switch state {
            case .speaking:
                jaw.phrase(&random)
                nextMumble = t
            case .happy:
                jaw.laugh(&random)
                nextMumble = t + 2.5 + random.next() * 3
            case .listening:
                jaw.hum(&random)
                self.pitch.v -= 0.5
                nextMumble = t + 3 + random.next() * 3
            case .idle, .thinking:
                jaw.hum(&random)
                nextMumble = t + 6 + random.next() * 8
            default:
                nextMumble = t + 4
            }
        }
        if mouth != nil { jaw.clear() }
        jaw.step(dt)
        /* a level from outside, eased so it never chatters: quick to open, slower to close */
        let outside = mouth.map { clamp($0, 0, 1) } ?? 0
        mouthLevel.step(outside, dt: dt, freq: outside > mouthLevel.x ? 11 : 6, damping: 0.85)

        /* blinks now and then, a double one sometimes */
        if t > nextBlink && state != .sleeping {
            if seq == nil { play(.blink) }
            nextBlink = t + 2.5 + random.next() * 4
            if random.next() < 0.15 { nextBlink = t + 0.4 }
        }
        let s = springs.face
        let talk = max(0, jaw.spring.x) * 0.85 + max(0, mouthLevel.x) * 0.9
        face = s
        face.jawOpen = s.jawOpen + talk
        /* a scripted change, laid over the springs so it keeps its own timing */
        if let playing = seq {
            let sequence = playing.name.sequence
            sequence.apply(at: playing.t, to: &face)
            let t = playing.t + dt
            seq = t > sequence.length ? nil : (playing.name, t)
        }

        /* an action's motion is shaped already, so it goes on top of the springs rather than through them */
        pose.yaw = self.yaw.x + ay + errShake
        /* talking nods the head a touch with each syllable */
        pose.pitch = self.pitch.x - talk * 0.04 + ap
        pose.roll = self.roll.x + ar
        /* a slow float, the state's own bob, and any hop */
        pose.lift = sin(t * 1.1) * 0.012 + lift + max(0, bounce.x) * 0.25
    }
}

/// Each state's pose at rest, for a first frame and for still or reduced-motion heads.
let restPose: [CharacterState: RobotPose] = [
    .idle: RobotPose(yaw: -0.1, pitch: 0.02, roll: 0.02),
    .thinking: RobotPose(yaw: 0.22, pitch: 0.16, roll: -0.1),
    .searching: RobotPose(yaw: 0.3, pitch: 0.03, roll: -0.03),
    .listening: RobotPose(yaw: -0.12, pitch: 0.03, roll: 0.15),
    .speaking: RobotPose(yaw: 0.04, pitch: 0.02, roll: 0),
    .working: RobotPose(yaw: 0, pitch: -0.18, roll: 0),
    .happy: RobotPose(yaw: 0, pitch: 0.04, roll: 0.05),
    .error: RobotPose(yaw: 0, pitch: -0.12, roll: -0.05),
    .sleeping: RobotPose(yaw: 0.05, pitch: -0.3, roll: 0.1),
]
