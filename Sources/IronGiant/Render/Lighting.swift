// The studio lighting of src/robot/light.ts, on the CPU: the GPU evaluates the
// same model per fragment (Shaders.swift), and the CPU needs it for the few
// flat colours it hands the GPU (the shut lids). All in linear light.

import simd

struct LitMaterial: Equatable {
    /// Linear albedo.
    var albedo: SIMD3<Double>
    /// Clear-coat reflectance face on; it rises to 1 at grazing angles.
    var f0: Double
    /// How much of the reflection takes the albedo's colour (metal).
    var metal: Double
    /// The key's tight highlight.
    var spec: Double
    var shininess: Double
    var rim: Double
    /// How much of the studio shows in its reflections.
    var sheen = 1.0
    /// 0 … 1: how far the diffuse light is pressed toward an even fill, for a flatter, painted look.
    var flat = 0.0
}

/// The shell's materials for a shell colour (sRGB 0–255), as `palette()` in render.ts.
struct Palette: Equatable {
    var shell: LitMaterial
    var dark: LitMaterial

    /// The default shell: a weathered gunmetal.
    static let defaultShell = SIMD3<Double>(60, 55, 63)

    init(shell rgb: SIMD3<Double>) {
        let a = Lighting.linear(rgb)
        shell = LitMaterial(albedo: a, f0: 0.02, metal: 0.2, spec: 0.06, shininess: 10, rim: 0.35, sheen: 0.22, flat: 0.45)
        dark = LitMaterial(albedo: a * 0.32, f0: 0.03, metal: 0.3, spec: 0.06, shininess: 12, rim: 0.3, flat: 0.4)
    }
}

enum Lighting {
    static let key = simd_normalize(SIMD3<Double>(-0.5, -0.78, 0.62))
    static let fill = simd_normalize(SIMD3<Double>(0.85, 0.15, 0.5))
    static let back = simd_normalize(SIMD3<Double>(0.55, -0.55, -0.62))
    static let half = simd_normalize(SIMD3<Double>(key.x, key.y, key.z + 1))

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// The studio seen in a reflection along r.
    static func environment(_ r: SIMD3<Double>) -> Double {
        let up = -r.y
        let horizon = 0.05 + 0.12 * smooth(-0.25, 0.3, up)
        let softbox = 1.1 * smooth(0.42, 0.78, up) * smooth(-0.9, -0.2, r.z - 0.6 * abs(r.x))
        let window = 2.6 * smooth(0.86, 0.97, simd_dot(r, key))
        let strip = 0.5 * smooth(0.6, 0.85, -r.x) * smooth(-0.35, 0.05, up) * (1 - smooth(0.2, 0.5, up))
        return horizon + softbox + window + strip
    }

    /// sRGB 0–255 → linear, with the TS's plain 2.2 gamma.
    static func linear(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(pow(rgb.x / 255, 2.2), pow(rgb.y / 255, 2.2), pow(rgb.z / 255, 2.2))
    }

    /// The ACES-like curve, then the 2.2 encoding: linear light → display 0–1 (the TS rounds to bytes here).
    static func display(_ x: Double) -> Double {
        let t = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)
        return pow(min(1, max(0, t)), 1 / 2.2)
    }

    static func display(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(display(c.x), display(c.y), display(c.z))
    }

    /// The surface's colour at a world-space normal, as linear light.
    static func radiance(_ m: LitMaterial, _ n: SIMD3<Double>) -> SIMD3<Double> {
        let ndl = simd_dot(n, key)
        // a little wrap so the terminator is soft, like a moulded part
        let keyLight = max(0, (ndl + 0.12) / 1.12)
        let fillLight = max(0, simd_dot(n, fill))
        let sky = 0.5 - 0.5 * n.y
        let ndv = max(0, n.z)
        let fres = m.f0 + (1 - m.f0) * pow(1 - ndv, 5)
        // reflection of the view ray
        let r = SIMD3(2 * ndv * n.x, 2 * ndv * n.y, 2 * ndv * n.z - 1)
        let env = environment(r) * fres * m.sheen
        let spec = m.spec * pow(max(0, simd_dot(n, half)), m.shininess)
        let b = max(0, simd_dot(n, back))
        let rim = m.rim * b * b * pow(1 - ndv, 1.6)
        let lit = 0.05 + 0.1 * sky + 1.25 * keyLight + 0.16 * fillLight
        let diffuse = lit + m.flat * (0.62 - lit)
        // the rim is a cool back light
        let rimTint = SIMD3<Double>(0.62, 0.78, 1)
        let a = m.albedo
        let tint = 1 - m.metal + m.metal * a * 2.2
        return a * diffuse * (1 - fres * 0.6) + (env + spec) * tint + rim * rimTint * (0.35 + a)
    }
}
