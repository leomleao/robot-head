import Testing
import simd
@testable import IronGiant

/// Expected values come from the TS (src/robot/geometry.ts, render.ts) run under Node.
@Suite struct GeometryTests {
    @Test func meshCountsMatchTheTypeScript() {
        let full = RobotMeshes.full, low = RobotMeshes.low
        #expect(full.cranium.positions.count == 1652)
        #expect(full.cranium.triangles.count == 3300)
        #expect(full.jaw.positions.count == 622)
        #expect(full.jaw.triangles.count == 1128)
        #expect(full.crest.isEmpty)
        #expect(low.cranium.triangles.count == 1134)
        #expect(low.jaw.triangles.count == 565)
        #expect(Set(full.cranium.materials) == [.shell, .inside])
        #expect(full.cranium.flatVertices.count == 3300 * 3)
        #expect(MemoryLayout<MeshVertex>.stride == 32)
    }

    @Test func decodingMatchesTheTypeScript() {
        let c = RobotMeshes.full.cranium
        #expect(c.positions[0] == SIMD3<Float>(0.1181640625, -0.04693603515625, -0.1829833984375))
        #expect(simd_distance(c.normals[0], SIMD3<Float>(0, 0.8643483519554138, -0.5028935670852661)) < 1e-6)
        #expect(abs(c.ys[0] - -0.0485026054084301) < 1e-7)
    }

    @Test func jawPanelAndTop() {
        #expect(RobotMeshes.jawPanel == JawPanel(x: 0.16552734375, z: 0.30218505859375, top: 0, bottom: 0.20233154296875))
        #expect(RobotMeshes.jawTop == 0.171142578125)
        // the TS bends this vertex furthest for a 0.7 smile
        let v = SIMD3<Double>(0.05950927734375, 0.1744384765625, 0.1712646484375)
        #expect(abs(jawSmileOffset(v, smile: 0.7) - 0.046405062079429626) < 1e-6)
    }

    @Test func headMeasurements() {
        #expect(Head.r == Double(Float(0.2854)))
        #expect(Head.eyeY == Double(Float(-0.26554)))
        #expect(Head.hingeY == Double(Float(-0.23709)))
    }

    @Test(arguments: [
        (240.0, 20.0, 44.0, 1.0, 258.15704553603445, 121.0, 195.7748296880602),
        (96.0, 9.0, 18.0, 1.0, 103.26281821441377, 49.0, 79.3099318752241),
        (160.0, 14.0, 30.0, 1.0, 172.10469702402295, 81.0, 131.18321979204018),
    ])
    func framingMatchesFrameFor(_ e: (Double, Double, Double, Double, Double, Double, Double)) {
        let f = Frame(box: e.0)
        #expect(f.padTop == e.1)
        #expect(f.padBottom == e.2)
        #expect(f.padSide == e.3)
        // Float32 model constants against the TS's doubles
        #expect(abs(f.unit - e.4) < 1e-4)
        #expect(f.cx == e.5)
        #expect(abs(f.cy - e.6) < 1e-4)
    }

    @Test func rotationMatchesTheTypeScript() {
        let ts = [0.9505637859220633, -0.15626088723942527, 0.26834869854847687, 0.09537450575679464, 0.9693090272746467, 0.22659151196707514, -0.29552020666133955, -0.18979606097868743, 0.9362933635841992]
        let r = rotation(yaw: 0.3, pitch: -0.2, roll: 0.1).rowMajor
        for (a, b) in zip(r, ts) { #expect(abs(a - b) < 1e-12) }
    }

    @Test func craniumFrontMatchesTheTypeScript() {
        let f = craniumFront(x: 0.1, y: -0.2)
        #expect(abs(f.z - 0.31048082709305463) < 1e-5)
        #expect(simd_distance(f.n, SIMD3(0.2874485373735191, 0.34771034293021336, 0.8924521588192714)) < 1e-4)
    }

    @Test func transformTurnsAboutThePivot() {
        let x = HeadTransform(pose: RobotPose(yaw: 0.4, pitch: 0.2, roll: -0.1), jawOpen: 0, cx: 100, cy: 200, u: 50)
        // the pivot stays put whatever the turn
        let p = x.head(SIMD3(0, Head.pivot, 0))
        #expect(abs(p.x - 100) < 1e-9 && abs(p.y - (200 + Head.pivot * 50)) < 1e-9)
        // a closed jaw only drops by `drop`
        let j = HeadTransform(pose: RobotPose(), jawOpen: 0, cx: 0, cy: 0, u: 100)
        let q = j.jaw(SIMD3(0, 0.1, 0.2))
        #expect(abs(q.y - (0.1 + j.drop) * 100) < 1e-9)
    }
}
