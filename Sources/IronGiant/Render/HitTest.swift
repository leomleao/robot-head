// "Is this point on the robot?" on the CPU: the light mesh turned and
// projected like the drawn one, and the point tested against the triangles
// that face the viewer. The projection is kept until the pose or the framing
// changes, so a query is a few microseconds; no GPU readback, no frame lag.

import simd

final class HeadHitTest {
    /// The light mesh in Double, once.
    private struct Part {
        let positions: [SIMD3<Double>]
        let triangles: [SIMD3<UInt16>]
        let normals: [SIMD3<Double>]

        init(_ m: Mesh) {
            positions = m.positions.map { SIMD3<Double>($0) }
            triangles = m.triangles
            normals = m.normals.map { SIMD3<Double>($0) }
        }
    }
    private static let cranium = Part(RobotMeshes.low.cranium)
    private static let jaw = Part(RobotMeshes.low.jaw)

    /// What the projection depends on.
    private struct Key: Equatable {
        var frame: Frame
        var origin: SIMD2<Double>
        var scale: Double
        var pose: RobotPose
        var jawOpen: Double
        var jawSmile: Double
    }

    /// A front-facing triangle on screen, with its bounds.
    private struct Triangle {
        var a, b, c: SIMD2<Double>
        var lo, hi: SIMD2<Double>
    }

    private var key: Key?
    private var triangles: [Triangle] = []
    private var lo = SIMD2<Double>(repeating: .infinity)
    private var hi = SIMD2<Double>(repeating: -.infinity)

    /// `point` in the scene's units (its `scale` per point, y down), against the scene as drawn.
    func contains(_ point: SIMD2<Double>, scene: RenderScene) -> Bool {
        var pose = scene.pose
        pose.yaw += scene.face.yaw
        pose.pitch += scene.face.pitch
        pose.roll += scene.face.roll
        let k = Key(frame: scene.frame, origin: scene.origin, scale: scene.scale, pose: pose, jawOpen: scene.face.jawOpen, jawSmile: scene.face.jawSmile)
        if k != key {
            project(k)
            key = k
        }
        if point.x < lo.x || point.y < lo.y || point.x > hi.x || point.y > hi.y { return false }
        for t in triangles where point.x >= t.lo.x && point.y >= t.lo.y && point.x <= t.hi.x && point.y <= t.hi.y {
            if Self.inside(point, t.a, t.b, t.c) { return true }
        }
        return false
    }

    private func project(_ k: Key) {
        let u = k.frame.unit * k.scale
        let x = HeadTransform(pose: k.pose, jawOpen: k.jawOpen, cx: (k.origin.x + k.frame.cx) * k.scale, cy: (k.origin.y + k.frame.cy) * k.scale, u: u)
        triangles.removeAll(keepingCapacity: true)
        lo = SIMD2(repeating: .infinity)
        hi = SIMD2(repeating: -.infinity)
        add(Self.cranium, project: { x.head($0) }, normal: { x.normal($0) })
        let smile = k.jawSmile
        add(Self.jaw, project: { p in x.jaw(SIMD3(p.x, p.y + jawSmileOffset(p, smile: smile), p.z)) }, normal: { x.jawNormal($0) })
    }

    private func add(_ part: Part, project: (SIMD3<Double>) -> SIMD3<Double>, normal: (SIMD3<Double>) -> SIMD3<Double>) {
        let screen = part.positions.map { v -> SIMD2<Double> in
            let s = project(v)
            return SIMD2(s.x, s.y)
        }
        for (i, tri) in part.triangles.enumerated() where normal(part.normals[i]).z >= -0.04 {
            let a = screen[Int(tri.x)], b = screen[Int(tri.y)], c = screen[Int(tri.z)]
            let tlo = simd_min(a, simd_min(b, c)), thi = simd_max(a, simd_max(b, c))
            triangles.append(Triangle(a: a, b: b, c: c, lo: tlo, hi: thi))
            lo = simd_min(lo, tlo)
            hi = simd_max(hi, thi)
        }
    }

    /// Whether p is in triangle abc, whichever way it winds.
    private static func inside(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
        func cross(_ o: SIMD2<Double>, _ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double {
            (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x)
        }
        let d1 = cross(p, a, b), d2 = cross(p, b, c), d3 = cross(p, c, a)
        let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
        return !(neg && pos)
    }
}
