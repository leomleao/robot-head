// The robot as triangle meshes in head units: x right, y down, z toward the
// viewer, the origin at the middle of the mouth line (the cranium's lower
// edge), as in src/robot/geometry.ts.
//
// The head and its jaw come from a sculpt (see ModelData.swift), decimated to
// a few thousand triangles: a domed cranium round in section, and a jaw like a
// bucket hanging from two arms pinned at the back of the head, so opening it
// swings the chin down and back. Each triangle has its own normal, as the TS
// lights each quad flat, so the GPU gets three vertices per triangle.

import Foundation
import simd

/// The head's measurements in head units.
enum Head {
    /// The cranium's radius at the mouth line.
    static let r = Double(ModelData.profile[0].y)
    /// The eyes: centres, the socket's radius, the glow's share of it. A little wider apart and
    /// larger than the sculpt's bowls, as in the film: 0.49 and 0.32 of the cranium's width.
    static let eyeX = 0.147
    static let eyeY = Double(ModelData.eyes[1].y)
    static let eyeZ = Double(ModelData.eyes[1].z)
    static let socket = 0.1
    static let glow = 0.75
    /// The jaw's hinge pins.
    static let hingeY = Double(ModelData.hinge.x)
    static let hingeZ = Double(ModelData.hinge.y)
    /// Where the head turns: its middle, a little behind the eyes.
    static let pivot = -0.16
    /// The head's reach at rest, for framing: the top of the crest, the bottom of the jaw, the hinge lugs at the sides.
    static let top = Double(ModelData.bounds.x)
    static let bottom = Double(ModelData.bounds.y)
    static let side = Double(ModelData.bounds.z)
}

/// A material slot per triangle.
enum Material: UInt8 {
    case shell = 0
    case dark = 1
    /// The inside of the head and the mouth: unlit, a cavity rather than a surface.
    case inside = 2
}

/// One part of the sculpt, decoded.
struct Mesh {
    var positions: [SIMD3<Float>]
    var triangles: [SIMD3<UInt16>]
    /// Outward, unit length, one per triangle.
    var normals: [SIMD3<Float>]
    /// Each triangle's height in the model, for the grime toward the bottom.
    var ys: [Float]
    var materials: [Material]

    init(_ part: ModelData.Part) {
        let p16: [Int16] = Self.decode(part.pos)
        let tri: [UInt16] = Self.decode(part.tri)
        let n8: [Int8] = Self.decode(part.nrm)
        let mats: [UInt8] = Self.decode(part.mat)
        positions = stride(from: 0, to: p16.count, by: 3).map {
            SIMD3(Float(p16[$0]), Float(p16[$0 + 1]), Float(p16[$0 + 2])) / ModelData.q
        }
        let count = tri.count / 3
        triangles = (0..<count).map { SIMD3(tri[$0 * 3], tri[$0 * 3 + 1], tri[$0 * 3 + 2]) }
        normals = (0..<count).map { t in
            let n = SIMD3<Double>(Double(n8[t * 3]), Double(n8[t * 3 + 1]), Double(n8[t * 3 + 2]))
            let l = simd_length(n)
            return SIMD3<Float>(l > 0 ? n / l : n)
        }
        let positions = positions
        ys = triangles.map { t in
            (positions[Int(t.x)].y + positions[Int(t.y)].y + positions[Int(t.z)].y) / 3
        }
        materials = mats.map { Material(rawValue: $0) ?? .shell }
    }

    var isEmpty: Bool { triangles.isEmpty }

    /// Little-endian values packed in base64.
    private static func decode<T: FixedWidthInteger>(_ base64: String) -> [T] {
        guard !base64.isEmpty, let data = Data(base64Encoded: base64) else { return [] }
        return data.withUnsafeBytes { raw in
            (0..<raw.count / MemoryLayout<T>.size).map {
                T(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<T>.size, as: T.self))
            }
        }
    }
}

/// The jaw's flat front panel: its half width, how far forward it stands, its top and bottom.
struct JawPanel: Equatable {
    var x: Double
    var z: Double
    var top: Double
    var bottom: Double
}

/// The head's meshes at one level of detail.
struct RobotMeshes {
    var cranium: Mesh
    /// This sculpt's crest is part of its cranium, so this is empty; kept to match the model's parts.
    var crest: Mesh
    var jaw: Mesh

    init(_ model: ModelData.Model) {
        cranium = Mesh(model.head)
        crest = Mesh(model.crest)
        jaw = Mesh(model.jaw)
    }

    static let full = RobotMeshes(ModelData.full)
    /// About a third of the triangles, for small sizes and the low quality tier.
    static let low = RobotMeshes(ModelData.low)

    /// Below this many device px per head unit, the head is drawn from the lighter mesh: a 100 px box at 2× is about 215.
    static let lowDetailBelow = 230.0

    /// The flat front panel: the full jaw's vertices that reach (almost) furthest forward.
    static let jawPanel: JawPanel = {
        let j = full.jaw.positions
        let front = j.map { Double($0.z) }.max() ?? 0
        var panel = JawPanel(x: 0, z: front, top: .infinity, bottom: -.infinity)
        for v in j where Double(v.z) >= front - 0.004 {
            panel.x = max(panel.x, Double(abs(v.x)))
            panel.top = min(panel.top, Double(v.y))
            panel.bottom = max(panel.bottom, Double(v.y))
        }
        return panel
    }()

    /// The top of the jaw's front, where the smile bends it most (from the full jaw, as in TS).
    static let jawTop: Double = {
        var top = Double.infinity
        for v in full.jaw.positions where v.z > 0.15 && abs(v.x) < 0.1 { top = min(top, Double(v.y)) }
        return top
    }()
}

/// How far the jaw's top edge bends at a rest vertex for `smile`, −1 frown … 1 smile: for a smile
/// its middle sinks while the corners stay at the mouth line, so the dark of the mouth opens as a
/// crescent; for a frown the corners sink instead. Only the front of the band bends, most at its
/// top edge, fading out a little way down. The GPU does the same per vertex; this is for the CPU.
func jawSmileOffset(_ v: SIMD3<Double>, smile: Double) -> Double {
    if abs(smile) < 1e-3 || v.z < 0.05 { return 0 }
    let near = 1 - min(1, max(0, (v.y - RobotMeshes.jawTop) / 0.1))
    if near <= 0 { return 0 }
    let across = min(1, abs(v.x) / 0.3)
    let front = min(1, v.z / 0.18)
    let shape = smile > 0 ? 1 - across * across : across * across
    return abs(smile) * 0.075 * shape * near * front
}

/// The cranium's radius round its middle at a height, from the sculpt's profile.
private func craniumRadius(_ y: Double) -> Double {
    let profile = ModelData.profile.map { SIMD2<Double>($0) }
    if y >= profile[0].x { return profile[0].y }
    for i in 1..<profile.count where y >= profile[i].x {
        let a = profile[i - 1], b = profile[i]
        return a.y + (y - a.x) / (b.x - a.x) * (b.y - a.y)
    }
    return 0
}

/// Where the cranium's front surface is at (x, y), and its outward normal there.
func craniumFront(x: Double, y: Double) -> (z: Double, n: SIMD3<Double>) {
    func f(_ xx: Double, _ yy: Double) -> Double {
        let r = craniumRadius(yy)
        return (max(0, r * r - xx * xx)).squareRoot()
    }
    let e = 0.002
    let dzdx = (f(x + e, y) - f(x - e, y)) / (2 * e)
    let dzdy = (f(x, y + e) - f(x, y - e)) / (2 * e)
    return (f(x, y), simd_normalize(SIMD3(-dzdx, -dzdy, 1)))
}

// MARK: - GPU layout

/// One vertex of a flat-shaded triangle, as the mesh shader reads it. 32 bytes.
struct MeshVertex {
    var x, y, z: Float
    var nx, ny, nz: Float
    /// The triangle's height in the model, for the grime.
    var grimeY: Float
    /// `Material.rawValue`.
    var material: Float
}

extension Mesh {
    /// Three vertices per triangle, each with the triangle's normal.
    var flatVertices: [MeshVertex] {
        var out: [MeshVertex] = []
        out.reserveCapacity(triangles.count * 3)
        for (t, tri) in triangles.enumerated() {
            let n = normals[t]
            for i in [tri.x, tri.y, tri.z] {
                let p = positions[Int(i)]
                out.append(MeshVertex(x: p.x, y: p.y, z: p.z, nx: n.x, ny: n.y, nz: n.z, grimeY: ys[t], material: Float(materials[t].rawValue)))
            }
        }
        return out
    }
}
