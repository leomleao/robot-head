// Where the head sits in its canvas, and the head's transform for a frame:
// the same numbers as frameFor and HeadXform in src/robot/render.ts.

import CharacterKit
import CoreGraphics
import simd

/// The head's pose: the sim's, plus the face's offsets. Radians; `x` and `lift` in head units.
struct RobotPose: Equatable {
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0
    /// The head's drift, sideways and up.
    var x = 0.0
    var lift = 0.0
}

/// Where the head sits, in points. The resting head is centred in a `box` × `box` square and fills
/// it; the canvas reaches past it by `pad*` on each side. `cx`, `cy` place the middle of the mouth
/// line (the model's origin) at rest; `unit` is one head unit.
struct Frame: Equatable {
    var box: Double
    var padTop: Double
    var padBottom: Double
    var padSide: Double
    var unit: Double
    var cx: Double
    var cy: Double

    /// The head at rest fills the box but for this inset, as a share of it.
    static let boxInset = 0.05
    /// Room past the head for motion, in head units: a nod or tilt, the bob, the glow, and the floor's shadow below.
    static let reachUp = 0.12
    static let reachSide = 0.1
    static let reachShadow = 0.14
    /// How far below the chin the floor is.
    static let floor = 0.07

    init(box: Double) {
        let tall = Head.bottom - Head.top, wide = 2 * Head.side
        let inner = box * (1 - 2 * Self.boxInset)
        let unit = min(inner / tall, inner / wide)
        // the resting head, centred in the box
        let above = (box - tall * unit) / 2
        let originY = above - Head.top * unit
        padTop = (max(0, Self.reachUp * unit - above) + 1).rounded(.up)
        padBottom = (max(0, (Self.floor + Self.reachShadow) * unit - above) + 1).rounded(.up)
        padSide = (max(0, Self.reachSide * unit - (box - wide * unit) / 2) + 1).rounded(.up)
        self.box = box
        self.unit = unit
        cx = padSide + box / 2
        cy = padTop + originY
    }

    var width: Double { box + 2 * padSide }
    var height: Double { box + padTop + padBottom }

    var framing: CharacterFraming {
        CharacterFraming(box: box, canvasSize: CGSize(width: width, height: height), boxOrigin: CGPoint(x: padSide, y: padTop))
    }
}

/// v' = Roll · Yaw · Pitch · v, as rows.
func rotation(yaw: Double, pitch: Double, roll: Double) -> simd_double3x3 {
    let cy = cos(yaw), sy = sin(yaw)
    let cp = cos(pitch), sp = sin(pitch)
    let cr = cos(roll), sr = sin(roll)
    let a0 = cy, a1 = sy * sp, a2 = sy * cp, a3 = 0.0, a4 = cp, a5 = -sp, a6 = -sy, a7 = cy * sp, a8 = cy * cp
    return simd_double3x3(rows: [
        SIMD3(cr * a0 - sr * a3, cr * a1 - sr * a4, cr * a2 - sr * a5),
        SIMD3(sr * a0 + cr * a3, sr * a1 + cr * a4, sr * a2 + cr * a5),
        SIMD3(a6, a7, a8),
    ])
}

/// The head's transform for a frame: turn about the pivot, then drift. Screen coordinates are in
/// whatever unit `cx`, `cy` and `scale` are given in (points for hit-testing, pixels for drawing).
struct HeadTransform {
    var r = matrix_identity_double3x3
    /// The jaw's swing about its hinge: cos and sin of the angle.
    var jawCos = 1.0
    var jawSin = 0.0
    var cx = 0.0
    var cy = 0.0
    /// Pixels (or points) per head unit.
    var u = 1.0
    var dx = 0.0
    var dy = 0.0
    /// How far the jaw hangs below the cranium at rest: the dark slit of the mouth.
    var drop = 0.0

    init() {}

    /// `pose` already includes the face's offsets.
    init(pose: RobotPose, jawOpen: Double, cx: Double, cy: Double, u: Double) {
        r = rotation(yaw: pose.yaw, pitch: pose.pitch, roll: pose.roll)
        // the jaw swings down and back about its hinge
        let th = max(0, jawOpen) * 0.5
        jawCos = cos(th)
        jawSin = sin(th)
        self.cx = cx
        self.cy = cy
        self.u = u
        dx = pose.x
        dy = -pose.lift
        // about 3% of the head's width, and never under two and a half pixels, so a small head keeps its mouth
        drop = max(0.018, 2.5 / u)
    }

    /// A model point on the head → (screen x, screen y, depth toward the viewer).
    func head(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let q = SIMD3(p.x, p.y - Head.pivot, p.z)
        let w = r * q + SIMD3(0, Head.pivot, 0)
        return SIMD3(cx + (w.x + dx) * u, cy + (w.y + dy) * u, w.z)
    }

    /// A model point on the jaw (before it swings) → screen, through the hinge then the head.
    func jaw(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let hy = p.y - Head.hingeY, hz = p.z - Head.hingeZ
        return head(SIMD3(p.x, Head.hingeY + jawCos * hy + jawSin * hz + drop, Head.hingeZ - jawSin * hy + jawCos * hz))
    }

    /// A normal on the head → world.
    func normal(_ n: SIMD3<Double>) -> SIMD3<Double> {
        r * n
    }

    func jawNormal(_ n: SIMD3<Double>) -> SIMD3<Double> {
        normal(SIMD3(n.x, jawCos * n.y + jawSin * n.z, -jawSin * n.y + jawCos * n.z))
    }
}

extension simd_double3x3 {
    /// The rows as the TS's row-major array.
    var rowMajor: [Double] {
        let t = transpose
        return [t.columns.0, t.columns.1, t.columns.2].flatMap { [$0.x, $0.y, $0.z] }
    }
}
