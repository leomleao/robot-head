// The face as a flat set of numbers. Expressions are targets for it, the
// sim and the actions nudge it, and springs carry it from one target to
// the next, so any change of face eases across instead of cutting.
//
// Eyes do the acting. Each glows as a disc inside a dark socket, and two
// dark lids cut into the disc from above and below: the top lid's angle is
// the brow (inner corner down reads as anger, up as worry), the bottom
// lid's curve is a smile in the eyes. The jaw opens about its hinge, and
// its top edge bends into a smile or a frown.
//
// A port of src/robot/rig.ts. Faces are values here, so the TS `cloneFace`
// is a plain copy and `mixFace` returns its result.

import CharacterKit
import Foundation

struct EyeRig: Equatable {
    /// How far each lid has closed over the disc, 0 open … 1 to the middle.
    var lidTop = 0.0
    var lidBottom = 0.0
    /// The top lid's tilt in radians; positive drops its inner corner (anger).
    var lidAngle = 0.0
    /// The bottom lid's edge: 0 straight, 1 curved up like a smiling cheek.
    var lidCurve = 0.0
    /// The glow's brightness and size, 1 at rest.
    var glow = 1.0
    var size = 1.0
    /// 0 a round disc … 1 a pentagon (defence mode).
    var shape = 0.0
    /// The iris closing over the glow: 0 none, then an opening that narrows to a pinpoint at 1.
    var pupil = 0.0
    /// Where the disc sits in the socket, −1 … 1 each way.
    var gazeX = 0.0
    var gazeY = 0.0

    /// The numbers in the TS `EYE_KEYS` order, which the springs and the traces use.
    static let slotCount = 10

    subscript(slot: Int) -> Double {
        get {
            switch slot {
            case 0: lidTop
            case 1: lidBottom
            case 2: lidAngle
            case 3: lidCurve
            case 4: glow
            case 5: size
            case 6: shape
            case 7: pupil
            case 8: gazeX
            case 9: gazeY
            default: preconditionFailure("no eye slot \(slot)")
            }
        }
        set {
            switch slot {
            case 0: lidTop = newValue
            case 1: lidBottom = newValue
            case 2: lidAngle = newValue
            case 3: lidCurve = newValue
            case 4: glow = newValue
            case 5: size = newValue
            case 6: shape = newValue
            case 7: pupil = newValue
            case 8: gazeX = newValue
            case 9: gazeY = newValue
            default: preconditionFailure("no eye slot \(slot)")
            }
        }
    }
}

struct FaceRig: Equatable {
    /// The robot's own, so they appear swapped on screen.
    var left = EyeRig()
    var right = EyeRig()
    /// The glow's colour, sRGB 0–255.
    var color = FaceRig.white
    /// 0 shut … 1 wide.
    var jawOpen = 0.04
    /// −1 frown … 1 smile.
    var jawSmile = 0.3
    /// Offsets added to the head's pose, radians.
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0

    /// The face's own numbers in the TS `FACE_KEYS` order.
    static let slotCount = 5

    subscript(slot: Int) -> Double {
        get {
            switch slot {
            case 0: jawOpen
            case 1: jawSmile
            case 2: yaw
            case 3: pitch
            case 4: roll
            default: preconditionFailure("no face slot \(slot)")
            }
        }
        set {
            switch slot {
            case 0: jawOpen = newValue
            case 1: jawSmile = newValue
            case 2: yaw = newValue
            case 3: pitch = newValue
            case 4: roll = newValue
            default: preconditionFailure("no face slot \(slot)")
            }
        }
    }

    static let white = SIMD3<Double>(255, 236, 226)
    static let red = SIMD3<Double>(255, 38, 24)
    static let pink = SIMD3<Double>(255, 150, 140)
    static let pinkish = SIMD3<Double>(255, 160, 150)
}

/// Some of an eye's numbers; nil takes the number from elsewhere (the base eye, or the target face).
struct EyePatch: Equatable {
    var lidTop: Double? = nil
    var lidBottom: Double? = nil
    var lidAngle: Double? = nil
    var lidCurve: Double? = nil
    var glow: Double? = nil
    var size: Double? = nil
    var shape: Double? = nil
    var pupil: Double? = nil
    var gazeX: Double? = nil
    var gazeY: Double? = nil

    subscript(slot: Int) -> Double? {
        switch slot {
        case 0: lidTop
        case 1: lidBottom
        case 2: lidAngle
        case 3: lidCurve
        case 4: glow
        case 5: size
        case 6: shape
        case 7: pupil
        case 8: gazeX
        case 9: gazeY
        default: preconditionFailure("no eye slot \(slot)")
        }
    }

    func over(_ eye: EyeRig) -> EyeRig {
        var e = eye
        for i in 0..<EyeRig.slotCount {
            if let v = self[i] { e[i] = v }
        }
        return e
    }
}

/// A full face; `eyes` goes on both eyes, then `left` and `right` on each.
private func face(
    eyes: EyePatch = EyePatch(), left: EyePatch = EyePatch(), right: EyePatch = EyePatch(),
    color: SIMD3<Double> = FaceRig.white,
    jawOpen: Double = 0.04, jawSmile: Double = 0.3, yaw: Double = 0, pitch: Double = 0, roll: Double = 0
) -> FaceRig {
    FaceRig(
        left: left.over(eyes.over(EyeRig())), right: right.over(eyes.over(EyeRig())),
        color: color, jawOpen: jawOpen, jawSmile: jawSmile, yaw: yaw, pitch: pitch, roll: roll
    )
}

extension FaceRig {
    /// Each expression as a full face; `color` is replaced by the eye colour
    /// except where the colour is the point (defence and attack).
    static let expressions: [CharacterExpression: FaceRig] = [
        .neutral: face(),
        .curious: face(eyes: EyePatch(lidTop: 0, size: 1.06, gazeY: -0.25), left: EyePatch(lidTop: 0.14, lidAngle: -0.12), jawOpen: 0, jawSmile: 0.1, yaw: -0.08, roll: 0.16),
        /* 08720: smiling eyes, the lower lids bowed up like cheeks, the head cocked */
        .happy: face(eyes: EyePatch(lidTop: 0.28, lidBottom: 0.3, lidCurve: 0.5), jawOpen: 0.2, jawSmile: 1, pitch: -0.05, roll: 0.14),
        .joyful: face(eyes: EyePatch(lidTop: 0, glow: 1.1, size: 1), jawOpen: 0.8, jawSmile: 1, pitch: 0.1),
        .sad: face(eyes: EyePatch(lidTop: 0.36, lidBottom: 0.1, lidAngle: -0.42, glow: 0.7, size: 0.9, gazeY: 0.55), jawOpen: 0.04, jawSmile: -0.55, pitch: -0.16, roll: 0.06),
        /* "Mmm": looking away and down, a small smile */
        .sheepish: face(eyes: EyePatch(lidTop: 0.22, lidBottom: 0.2, lidAngle: -0.22, lidCurve: 0.45, size: 0.88, gazeX: -0.7, gazeY: 0.5), jawOpen: 0.04, jawSmile: 0.3, pitch: -0.1, roll: -0.12),
        .sleepy: face(eyes: EyePatch(lidTop: 0.6, lidBottom: 0.12, lidAngle: -0.08, glow: 0.6, gazeY: 0.4), jawOpen: 0.03, jawSmile: 0, pitch: -0.14, roll: 0.06),
        /* a side-eye: one lid lower, the glow at the corner, the head turned against it */
        .suspicious: face(eyes: EyePatch(lidBottom: 0.26, lidAngle: 0.2, size: 0.85, gazeX: 0.9), left: EyePatch(lidTop: 0.56), right: EyePatch(lidTop: 0.3), jawOpen: 0.02, jawSmile: -0.1, yaw: -0.12, roll: -0.05),
        .content: face(eyes: EyePatch(lidTop: 0.38, lidBottom: 0.22, lidCurve: 1, glow: 0.8), jawOpen: 0.06, jawSmile: 0.5),
        /* an "O", not a grin */
        .surprised: face(eyes: EyePatch(lidTop: 0, glow: 1.3, size: 1.14), jawOpen: 0.4, jawSmile: -0.15, pitch: 0.1),
        /* "No. Stop. Why?": wide, worried, mouth pulled down */
        .afraid: face(eyes: EyePatch(lidTop: 0.12, lidAngle: -0.35, size: 1.1), jawOpen: 0.3, jawSmile: -0.4, pitch: 0.06),
        /* 09752: a narrow, level slit */
        .determined: face(eyes: EyePatch(lidTop: 0.42, lidBottom: 0.32, lidAngle: 0.18, gazeY: -0.15), jawOpen: 0.02, jawSmile: -0.05, pitch: -0.1),
        /* 06828: the red eye, wide open, the iris part way in */
        .angry: face(eyes: EyePatch(glow: 1.3, pupil: 0.35), color: FaceRig.red, jawOpen: 0.02, jawSmile: 0, pitch: -0.06),
        /* 09224–09230: pink slits under heavy angled lids, a grimace; no iris */
        .attack: face(eyes: EyePatch(lidTop: 0.22, lidAngle: 0.4, glow: 1.15), color: FaceRig.pink, jawOpen: 0.3, jawSmile: -0.25, pitch: -0.12),
        /* 06832: wide open, the iris down to a small opening */
        .defense: face(eyes: EyePatch(glow: 1.4, pupil: 0.82), color: FaceRig.red, jawOpen: 0.02, jawSmile: 0),
        /* 09928: the eyes half closed, looking up, the head tipped back */
        .peaceful: face(eyes: EyePatch(lidTop: 0.36, lidBottom: 0.26, lidCurve: 0.3, glow: 0.95, gazeY: -0.35), jawOpen: 0, jawSmile: 0.3, pitch: 0.22, roll: 0.1),
        .asleep: face(eyes: EyePatch(lidTop: 0.56, lidBottom: 0.46, glow: 0.1), jawOpen: 0, jawSmile: 0, pitch: -0.22, roll: 0.1),
    ]

    /// The expressions in the TS order (`EXPRESSION_NAMES`), which is CharacterKit's core order.
    static let expressionNames: [CharacterExpression] = CharacterExpression.core
}

extension CharacterExpression {
    /// Whether a face is one of the red ones (attack's is pink), which the eyes turn to and from by a sequence.
    var isRed: Bool { self == .angry || self == .attack || self == .defense }
}

// MARK: - Springs

/* every number in the rig, in a fixed order: both eyes, the face's own, the colour */
private let slots = EyeRig.slotCount * 2 + FaceRig.slotCount + 3

/* the lids move fastest, the head offsets slowest: a heavy robot with quick eyes */
private let springFreq: [Float] = {
    var f = [Float]()
    for _ in 0..<2 {
        // lidTop, lidBottom, lidAngle, lidCurve, glow, size, shape, pupil, gazeX, gazeY
        f += [4.2, 4.2, 4.2, 4.2, 3, 3, 3, 3, 5, 5]
    }
    f += [3.2, 3.2, 1.1, 1.1, 1.1]  // jawOpen, jawSmile, yaw, pitch, roll
    f += [2.6, 2.6, 2.6]            // colour
    return f
}()

/// Springs on every number of the face, chasing a target face. Critically
/// damped but for the head offsets, which overshoot a little and settle.
///
/// The TS keeps its state in `Float32Array`s, so this keeps it in `Float`
/// and does each step's arithmetic in `Double`, rounding on every store as
/// JS does.
struct FaceSprings {
    private(set) var face: FaceRig
    private var x = [Float](repeating: 0, count: slots)
    private var v = [Float](repeating: 0, count: slots)
    private var t = [Float](repeating: 0, count: slots)

    init(_ start: FaceRig) {
        face = start
        Self.write(start, into: &x)
    }

    /// Jump straight to a face, with no easing (a first frame, a still head).
    mutating func snap(_ f: FaceRig) {
        Self.write(f, into: &x)
        for i in 0..<slots { v[i] = 0 }
        Self.read(x, into: &face)
    }

    mutating func step(toward target: FaceRig, dt: Double, speed: Double = 1) {
        Self.write(target, into: &t)
        /* TS sets `head` to 23, one past yaw, so the overshoot lands on pitch, roll
           and the colour's red channel, not on yaw; kept as it is for parity */
        let head = EyeRig.slotCount * 2 + 3
        for i in 0..<slots {
            let w = Double(springFreq[i]) * speed * Double.pi * 2
            let zeta = i >= head && i < head + 3 ? 0.62 : 1
            v[i] = Float(Double(v[i]) + (w * w * (Double(t[i]) - Double(x[i])) - 2 * zeta * w * Double(v[i])) * dt)
            x[i] = Float(Double(x[i]) + Double(v[i]) * dt)
        }
        Self.read(x, into: &face)
    }

    private static func write(_ f: FaceRig, into out: inout [Float]) {
        var i = 0
        for k in 0..<EyeRig.slotCount { out[i] = Float(f.left[k]); i += 1 }
        for k in 0..<EyeRig.slotCount { out[i] = Float(f.right[k]); i += 1 }
        for k in 0..<FaceRig.slotCount { out[i] = Float(f[k]); i += 1 }
        /* colour blends in linear light, so red to white does not pass through mud */
        for c in 0..<3 { out[i] = Float(pow(f.color[c] / 255, 2.2)); i += 1 }
    }

    private static func read(_ v: [Float], into f: inout FaceRig) {
        var i = 0
        for k in 0..<EyeRig.slotCount { f.left[k] = Double(v[i]); i += 1 }
        for k in 0..<EyeRig.slotCount { f.right[k] = Double(v[i]); i += 1 }
        for k in 0..<FaceRig.slotCount { f[k] = Double(v[i]); i += 1 }
        for c in 0..<3 { f.color[c] = 255 * pow(max(0, Double(v[i])), 1 / 2.2); i += 1 }
    }
}

/// A face blended a share `k` of the way from `a` to `b`.
func mixFace(_ a: FaceRig, _ b: FaceRig, _ k: Double) -> FaceRig {
    func l(_ p: Double, _ q: Double) -> Double { p + (q - p) * k }
    var out = a
    for i in 0..<EyeRig.slotCount {
        out.left[i] = l(a.left[i], b.left[i])
        out.right[i] = l(a.right[i], b.right[i])
    }
    for i in 0..<FaceRig.slotCount { out[i] = l(a[i], b[i]) }
    for c in 0..<3 { out.color[c] = 255 * pow(l(pow(a.color[c] / 255, 2.2), pow(b.color[c] / 255, 2.2)), 1 / 2.2) }
    return out
}

// MARK: - Sequences

/// One key of a sequence: some of the eyes' numbers and perhaps the colour.
struct FacePatch: Equatable {
    var eyes: EyePatch? = nil
    var color: SIMD3<Double>? = nil
}

/// A scripted change of face, keyed from the film frame by frame (at 24 fps
/// a frame is about 0.04 s). Each key sets some of the eyes' numbers and
/// perhaps the colour; a nil key stands for the face the robot is aiming
/// for, so a sequence ending on nil hands over to it without a jump. A field
/// a key leaves out takes the target's value at that key.
struct FaceSequence {
    let keys: [(time: Double, patch: FacePatch?)]

    var length: Double { keys[keys.count - 1].time }

    /* the eye numbers a key may set */
    private static let patchSlots = [0, 1, 4, 6, 7, 5]  // lidTop, lidBottom, glow, shape, pupil, size

    /// Lay the sequence, `t` seconds in, over `face` (which holds the target face).
    func apply(at t: Double, to face: inout FaceRig) {
        var i = 0
        while i < keys.count - 2 && keys[i + 1].time <= t { i += 1 }
        let (t0, a) = keys[i], (t1, b) = keys[i + 1]
        let k = min(1, max(0, (t - t0) / max(1e-6, t1 - t0)))
        /* ease each segment in and out */
        let e = k * k * (3 - 2 * k)
        func blend(_ eye: inout EyeRig) {
            for slot in Self.patchSlots {
                let va = a?.eyes?[slot] ?? eye[slot]
                let vb = b?.eyes?[slot] ?? eye[slot]
                eye[slot] = va + (vb - va) * e
            }
        }
        blend(&face.left)
        blend(&face.right)
        let ca = a?.color ?? face.color, cb = b?.color ?? face.color
        for c in 0..<3 {
            let la = pow(ca[c] / 255, 2.2), lb = pow(cb[c] / 255, 2.2)
            face.color[c] = 255 * pow(la + (lb - la) * e, 1 / 2.2)
        }
    }
}

private let shut = EyePatch(lidTop: 0.56, lidBottom: 0.46)

extension FaceSequence {
    /* 9920–9929: the lids meet and part again, quick */
    static let blink = FaceSequence(keys: [(0, nil), (0.07, FacePatch(eyes: shut)), (0.1, FacePatch(eyes: shut)), (0.2, nil)])
    /* 6825–6834: the white eye flushes pink, turns to a red pentagon, then the iris closes in (about 10 frames) */
    static let defenseOn = FaceSequence(keys: [
        (0, nil),
        (0.06, FacePatch(eyes: EyePatch(glow: 1.15, shape: 0.6, pupil: 0), color: FaceRig.pinkish)),
        (0.12, FacePatch(eyes: EyePatch(glow: 1.25, shape: 1, pupil: 0), color: FaceRig.red)),
        (0.22, FacePatch(eyes: EyePatch(glow: 1.3, shape: 1, pupil: 0.3), color: FaceRig.red)),
        (0.42, nil),
    ])
    /* 8309–8312: four frames; the iris opens on a red pentagon that pales to a small pink one, then the white eye */
    static let defenseOff = FaceSequence(keys: [
        (0, nil),
        (0.05, FacePatch(eyes: EyePatch(shape: 1, pupil: 0.3), color: FaceRig.red)),
        (0.1, FacePatch(eyes: EyePatch(size: 0.85, shape: 1, pupil: 0), color: FaceRig.pinkish)),
        (0.17, FacePatch(eyes: EyePatch(shape: 0.3, pupil: 0))),
        (0.25, nil),
    ])
    /* 10550–10562: a long dark hold, the seam lights, then the eyes open in two frames and the glow catches up */
    static let wake = FaceSequence(keys: [
        (0, FacePatch(eyes: EyePatch(lidTop: 0.56, lidBottom: 0.46, glow: 0.1))),
        (0.45, FacePatch(eyes: EyePatch(lidTop: 0.56, lidBottom: 0.46, glow: 0.6))),
        (0.55, FacePatch(eyes: EyePatch(lidTop: 0.15, lidBottom: 0.1, glow: 0.7))),
        (0.65, FacePatch(eyes: EyePatch(lidTop: 0, lidBottom: 0, glow: 0.8))),
        (0.9, nil),
    ])
}

/// The scripted changes of face the sim plays (the TS `SEQUENCES`).
enum SequenceName: CaseIterable {
    case blink, defenseOn, defenseOff, wake

    var sequence: FaceSequence {
        switch self {
        case .blink: .blink
        case .defenseOn: .defenseOn
        case .defenseOff: .defenseOff
        case .wake: .wake
        }
    }
}
