// Drawing the Iron Giant with Metal. Two passes a frame:
//
// 1. the head, offscreen: the mouth's dark plate, the cranium and jaw meshes
//    through a depth buffer (multisampled at the higher tiers), and the jaw
//    panel's seams;
// 2. the canvas: the floor's shadow, the head over its ink outline, then each
//    eye with its bloom.
//
// The CPU works out a few dozen numbers per frame; the GPU does the rest.

import CharacterKit
import Metal
import simd

/// One eye's numbers, as the face rig has them.
struct RenderEye: Equatable {
    var lidTop = 0.0
    var lidBottom = 0.0
    var lidAngle = 0.0
    var lidCurve = 0.0
    var glow = 1.0
    var size = 1.0
    var shape = 0.0
    var pupil = 0.0
    var gazeX = 0.0
    var gazeY = 0.0
}

/// The face to draw: the robot's own left and right eyes, the glow's colour (sRGB 0–255), the jaw,
/// and offsets added to the head's pose.
struct RenderFace: Equatable {
    var left = RenderEye()
    var right = RenderEye()
    var color = SIMD3<Double>(255, 236, 226)
    var jawOpen = 0.04
    var jawSmile = 0.3
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0
}

/// Everything one frame needs.
struct RenderScene {
    var frame: Frame
    /// Where the frame's canvas starts in the target, in points.
    var origin = SIMD2<Double>(0, 0)
    /// Pixels per point.
    var scale = 2.0
    var pose = RobotPose()
    var face = RenderFace()
    /// The shell's colour, sRGB 0–255.
    var shell = Palette.defaultShell
    var shadow = true
}

// MARK: - GPU-side structs (layouts match Shaders.swift)

private struct HeadUniforms {
    var r0, r1, r2: SIMD4<Float>
    var view: SIMD4<Float>
    var head: SIMD4<Float>
    var jaw: SIMD4<Float>
    var hinge: SIMD4<Float>
}

private struct GPUMaterial {
    var albedoF0: SIMD4<Float>
    var p: SIMD4<Float>
    var q: SIMD4<Float>

    init(_ m: LitMaterial) {
        albedoF0 = SIMD4(SIMD3<Float>(m.albedo), Float(m.f0))
        p = SIMD4(Float(m.metal), Float(m.spec), Float(m.shininess), Float(m.rim))
        q = SIMD4(Float(m.sheen), Float(m.flat), 0, 0)
    }
}

private struct GPULighting {
    var shell: GPUMaterial
    var dark: GPUMaterial
    var inside: SIMD4<Float>
}

private struct LineUniforms {
    var ends: SIMD4<Float>
    var style: SIMD4<Float>
    var color: SIMD4<Float>
}

private struct QuadUniforms {
    var centerAxisX: SIMD4<Float>
    var axisYView: SIMD4<Float>
}

struct EyeUniforms {
    var axes: SIMD4<Float>
    var origin: SIMD4<Float>
    var glow: SIMD4<Float>
    var light: SIMD4<Float>
    var color: SIMD4<Float>
    var lids: SIMD4<Float>
    var lidColor: SIMD4<Float>
    var seam: SIMD4<Float>
    var seamColor: SIMD4<Float>
    var iris: SIMD4<Float>
}

/// sRGB bytes → 0–1.
private func byteColor(_ r: Double, _ g: Double, _ b: Double) -> SIMD3<Float> {
    SIMD3<Float>(Float(r), Float(g), Float(b)) / 255
}

enum Palette8 {
    /// The colour of every inside surface, and of the mouth's dark.
    static let inside = byteColor(12, 9, 10)
    /// The outline's colour.
    static let ink = byteColor(20, 15, 18)
    static let socket = byteColor(6, 5, 4)
}

/// The face round each eye faces a little out and up from the round of the head.
private let eyeNormalRight = simd_normalize(SIMD3<Double>(0.3, -0.16, 1))
private let eyeNormalLeft = SIMD3(-eyeNormalRight.x, eyeNormalRight.y, eyeNormalRight.z)

final class IronGiantRenderer {
    let device: any MTLDevice
    private let meshPipelines: [Int: any MTLRenderPipelineState]
    private let platePipelines: [Int: any MTLRenderPipelineState]
    private let linePipelines: [Int: any MTLRenderPipelineState]
    private let shadowPipeline: any MTLRenderPipelineState
    private let compositePipeline: any MTLRenderPipelineState
    private let eyePipeline: any MTLRenderPipelineState
    private let bloomPipeline: any MTLRenderPipelineState
    private let depthOn: any MTLDepthStencilState
    private let depthOff: any MTLDepthStencilState

    private struct MeshBuffers {
        let cranium: any MTLBuffer
        let craniumCount: Int
        let jaw: any MTLBuffer
        let jawCount: Int
    }
    private let fullMesh: MeshBuffers
    private let lowMesh: MeshBuffers
    private let plate: any MTLBuffer
    private let plateCount: Int

    /// The head pass's textures, kept while the size and sample count stay the same.
    private var headTexture: (any MTLTexture)?
    private var msaaTexture: (any MTLTexture)?
    private var depthTexture: (any MTLTexture)?
    private var targetKey: (width: Int, height: Int, samples: Int) = (0, 0, 0)

    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    static let depthFormat = MTLPixelFormat.depth32Float

    enum SetupError: Error {
        case buffer
        case function(String)
    }

    /// Compiles the shaders (asynchronously, off the calling thread) and uploads the meshes.
    static func make(device: any MTLDevice) async throws -> IronGiantRenderer {
        let library = try await device.makeLibrary(source: Shaders.source, options: nil)
        return try IronGiantRenderer(device: device, library: library)
    }

    private init(device: any MTLDevice, library: any MTLLibrary) throws {
        self.device = device
        func fn(_ name: String) throws -> any MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw SetupError.function(name) }
            return f
        }
        enum Blend { case none, over, add }
        func pipeline(_ v: String, _ f: String, samples: Int, depth: Bool, blend: Blend) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try fn(v)
            d.fragmentFunction = try fn(f)
            d.rasterSampleCount = samples
            let c = d.colorAttachments[0]!
            c.pixelFormat = Self.pixelFormat
            switch blend {
            case .none:
                break
            case .over, .add:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = blend == .add ? .one : .oneMinusSourceAlpha
                c.destinationAlphaBlendFactor = blend == .add ? .one : .oneMinusSourceAlpha
            }
            if depth { d.depthAttachmentPixelFormat = Self.depthFormat }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        var meshes: [Int: any MTLRenderPipelineState] = [:], plates: [Int: any MTLRenderPipelineState] = [:], lines: [Int: any MTLRenderPipelineState] = [:]
        for s in [1, 4] {
            meshes[s] = try pipeline("mesh_vertex", "mesh_fragment", samples: s, depth: true, blend: .none)
            plates[s] = try pipeline("plate_vertex", "plate_fragment", samples: s, depth: true, blend: .none)
            lines[s] = try pipeline("line_vertex", "line_fragment", samples: s, depth: true, blend: .over)
        }
        meshPipelines = meshes
        platePipelines = plates
        linePipelines = lines
        shadowPipeline = try pipeline("quad_vertex", "shadow_fragment", samples: 1, depth: false, blend: .over)
        compositePipeline = try pipeline("full_vertex", "composite_fragment", samples: 1, depth: false, blend: .over)
        eyePipeline = try pipeline("eye_vertex", "eye_fragment", samples: 1, depth: false, blend: .over)
        bloomPipeline = try pipeline("eye_vertex", "bloom_fragment", samples: 1, depth: false, blend: .add)

        let on = MTLDepthStencilDescriptor()
        on.depthCompareFunction = .less
        on.isDepthWriteEnabled = true
        let off = MTLDepthStencilDescriptor()
        off.depthCompareFunction = .always
        off.isDepthWriteEnabled = false
        guard let depthOn = device.makeDepthStencilState(descriptor: on),
              let depthOff = device.makeDepthStencilState(descriptor: off) else { throw SetupError.buffer }
        self.depthOn = depthOn
        self.depthOff = depthOff

        func upload<T>(_ array: [T]) throws -> any MTLBuffer {
            let bytes = max(1, array.count * MemoryLayout<T>.stride)
            guard let b = array.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: bytes, options: .storageModeShared) }) else { throw SetupError.buffer }
            return b
        }
        func meshBuffers(_ m: RobotMeshes) throws -> MeshBuffers {
            let c = m.cranium.flatVertices, j = m.jaw.flatVertices
            return MeshBuffers(cranium: try upload(c), craniumCount: c.count, jaw: try upload(j), jawCount: j.count)
        }
        fullMesh = try meshBuffers(.full)
        lowMesh = try meshBuffers(.low)
        let plateVertices = Self.mouthPlate()
        plate = try upload(plateVertices.map { [Float($0.x), Float($0.y), Float($0.z)] }.flatMap { $0 })
        plateCount = plateVertices.count
    }

    /// The dark inside of the mouth, in model space: a plate just behind the face, from the mouth
    /// line down into the jaw, and a wall across the middle of the head, so a turned head shows
    /// dark between the cranium and the jaw's arms. Triangles.
    static func mouthPlate() -> [SIMD3<Double>] {
        let steps = 12
        var top: [SIMD3<Double>] = [], bottom: [SIMD3<Double>] = []
        for i in 0...steps {
            let x = -Head.r * 0.85 + Double(i) / Double(steps) * Head.r * 1.7
            let z = craniumFront(x: x * 0.98, y: -0.01).z
            top.append(SIMD3(x, -0.02, z - 0.01))
            bottom.append(SIMD3(x, 0.1, z - 0.05))
        }
        var out: [SIMD3<Double>] = []
        for i in 0..<steps {
            out += [top[i], top[i + 1], bottom[i], top[i + 1], bottom[i + 1], bottom[i]]
        }
        let wall: [SIMD3<Double>] = [[-0.24, -0.03, -0.06], [0.24, -0.03, -0.06], [0.24, 0.1, -0.06], [-0.24, 0.1, -0.06]]
        out += [wall[0], wall[1], wall[2], wall[0], wall[2], wall[3]]
        return out
    }

    // MARK: - Drawing

    func encode(_ scene: RenderScene, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer, quality: QualityTier) {
        let width = target.width, height = target.height
        let scale = scene.scale
        let u = scene.frame.unit * scale
        let cx = (scene.origin.x + scene.frame.cx) * scale
        let cy = (scene.origin.y + scene.frame.cy) * scale
        let face = scene.face
        var pose = scene.pose
        pose.yaw += face.yaw
        pose.pitch += face.pitch
        pose.roll += face.roll
        let x = HeadTransform(pose: pose, jawOpen: face.jawOpen, cx: cx, cy: cy, u: u)
        let samples = quality == .low ? 1 : 4
        // a small head gets the lighter mesh: the difference doesn't show, the cost does
        let mesh = quality == .low || u < RobotMeshes.lowDetailBelow ? lowMesh : fullMesh
        guard prepareTargets(width: width, height: height, samples: samples), let headTexture else { return }

        // ── 1. the head, offscreen ──
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        color.loadAction = .clear
        if samples > 1 {
            color.texture = msaaTexture
            color.resolveTexture = headTexture
            color.storeAction = .multisampleResolve
        } else {
            color.texture = headTexture
            color.storeAction = .store
        }
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Iron Giant head"

        let r = x.r
        let rows = (0..<3).map { i in SIMD4<Float>(Float(r[0, i]), Float(r[1, i]), Float(r[2, i]), 0) }
        var head = HeadUniforms(
            r0: rows[0], r1: rows[1], r2: rows[2],
            view: SIMD4(Float(width), Float(height), Float(cx), Float(cy)),
            head: SIMD4(Float(u), Float(x.dx), Float(x.dy), Float(Head.pivot)),
            jaw: SIMD4(Float(x.jawCos), Float(x.jawSin), Float(x.drop), Float(face.jawSmile)),
            hinge: SIMD4(Float(Head.hingeY), Float(Head.hingeZ), Float(RobotMeshes.jawTop), 0)
        )
        // the inside of the mouth, behind everything else on the head
        enc.setRenderPipelineState(platePipelines[samples]!)
        enc.setDepthStencilState(depthOff)
        enc.setVertexBuffer(plate, offset: 0, index: 0)
        enc.setVertexBytes(&head, length: MemoryLayout<HeadUniforms>.stride, index: 1)
        var inside = SIMD4<Float>(Palette8.inside, 1)
        enc.setFragmentBytes(&inside, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: plateCount)

        // the cranium and the jaw
        let palette = Palette(shell: scene.shell)
        var lighting = GPULighting(shell: GPUMaterial(palette.shell), dark: GPUMaterial(palette.dark), inside: SIMD4(Palette8.inside, 1))
        enc.setRenderPipelineState(meshPipelines[samples]!)
        enc.setDepthStencilState(depthOn)
        enc.setFragmentBytes(&lighting, length: MemoryLayout<GPULighting>.stride, index: 0)
        enc.setVertexBuffer(mesh.cranium, offset: 0, index: 0)
        enc.setVertexBytes(&head, length: MemoryLayout<HeadUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.craniumCount)
        head.hinge.w = 1
        enc.setVertexBuffer(mesh.jaw, offset: 0, index: 0)
        enc.setVertexBytes(&head, length: MemoryLayout<HeadUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.jawCount)

        // ink along the edges of the jaw's flat front panel, as the film draws its facets
        let panel = RobotMeshes.jawPanel
        let facing = x.jawNormal(SIMD3(0, 0, 1)).z
        if facing >= 0.05 && panel.x > 0 {
            enc.setRenderPipelineState(linePipelines[samples]!)
            enc.setDepthStencilState(depthOff)
            for s in [-1.0, 1.0] {
                let a = x.jaw(SIMD3(s * panel.x, panel.top + 0.004, panel.z))
                let b = x.jaw(SIMD3(s * panel.x, panel.bottom - 0.004, panel.z))
                var line = LineUniforms(
                    ends: SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y)),
                    style: SIMD4(Float(max(1, u * 0.007)), Float(min(1, facing * 2.5)), Float(width), Float(height)),
                    color: SIMD4(Palette8.ink, 1)
                )
                enc.setVertexBytes(&line, length: MemoryLayout<LineUniforms>.stride, index: 0)
                enc.setFragmentBytes(&line, length: MemoryLayout<LineUniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        enc.endEncoding()

        // ── 2. the canvas ──
        let out = MTLRenderPassDescriptor()
        out.colorAttachments[0].texture = target
        out.colorAttachments[0].loadAction = .clear
        out.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        out.colorAttachments[0].storeAction = .store
        guard let canvas = commandBuffer.makeRenderCommandEncoder(descriptor: out) else { return }
        canvas.label = "Iron Giant canvas"

        // the floor's shadow, smaller and fainter the higher the head floats
        if scene.shadow {
            let up = max(0, scene.pose.lift)
            let rx = Head.r * 1.15 * (1 - up * 0.9) * u
            let a = 0.5 * max(0, 1 - up * 1.6)
            if rx > 0 && a > 0 {
                var quad = QuadUniforms(
                    centerAxisX: SIMD4(Float(cx + scene.pose.x * u), Float(cy + (Head.bottom + Frame.floor) * u), Float(rx), 0),
                    axisYView: SIMD4(0, Float(rx * 0.16), Float(width), Float(height))
                )
                var shadow = SIMD4<Float>(Float(a), 0, 0, 0)
                canvas.setRenderPipelineState(shadowPipeline)
                canvas.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
                canvas.setFragmentBytes(&shadow, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                canvas.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        // the head over its ink: the TS strokes every quad with its own fill, which grows the
        // silhouette by half a line; the outline reaches that much further to land in the same place
        let stroke = max(0.6, u / 300)
        var ink = SIMD4<Float>(Palette8.ink, Float(max(1, u * 0.008) + stroke / 2))
        canvas.setRenderPipelineState(compositePipeline)
        canvas.setFragmentTexture(headTexture, index: 0)
        canvas.setFragmentBytes(&ink, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        canvas.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // the eyes: the robot's right one is on the viewer's left
        for (eye, side) in [(face.right, -1.0), (face.left, 1.0)] {
            guard var e = Self.eyeUniforms(eye, side: side, face: face, palette: palette, transform: x, viewport: SIMD2(Double(width), Double(height))) else { continue }
            canvas.setRenderPipelineState(eyePipeline)
            canvas.setVertexBytes(&e, length: MemoryLayout<EyeUniforms>.stride, index: 0)
            canvas.setFragmentBytes(&e, length: MemoryLayout<EyeUniforms>.stride, index: 0)
            canvas.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            if e.light.w > 0.5 {
                canvas.setRenderPipelineState(bloomPipeline)
                canvas.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        canvas.endEncoding()
    }

    /// One eye's numbers for the GPU, or nil when it faces away. `side` is −1 for the eye on the
    /// viewer's left. Everything is in the eye's own patch of the face, in head units centred on
    /// the socket, as the TS draws it after mapping that patch's tangent plane to the screen.
    static func eyeUniforms(_ e: RenderEye, side: Double, face: RenderFace, palette: Palette, transform x: HeadTransform, viewport: SIMD2<Double>) -> EyeUniforms? {
        let smooth = Lighting.smooth
        let n = side < 0 ? eyeNormalLeft : eyeNormalRight
        let world = x.normal(n)
        if world.z < 0.08 { return nil }
        let ex = side * Head.eyeX, ey = Head.eyeY, z = Head.eyeZ
        // the tangent plane: a step along x and along y on the surface
        let tx = 1 / (1 + pow(n.x / n.z, 2)).squareRoot(), tzx = (-n.x / n.z) * tx
        let ty = 1 / (1 + pow(n.y / n.z, 2)).squareRoot(), tzy = (-n.y / n.z) * ty
        let o = x.head(SIMD3(ex, ey, z))
        let ax = x.head(SIMD3(ex + tx, ey, z + tzx)) - o
        let ay = x.head(SIMD3(ex, ey + ty, z + tzy)) - o
        // how much the face is turned from us: the socket's rim shows its far wall
        let facing = smooth(0.08, 0.6, world.z)

        let R = Head.socket
        let r = R * Head.glow * e.size
        let travel = max(0, R * 0.96 - r)
        let gx = e.gazeX * travel, gy = e.gazeY * travel + R * 0.08
        let bright = max(0, e.glow)
        let open = max(0, 1 - max(0, e.lidTop) - max(0, e.lidBottom))
        let iris = min(1, max(0, e.pupil))
        let shows = open > 0.001 && bright > 0.001
        // a small head gets a wider core so its eyes still pop
        let corePart = 0.14 + 0.2 * (1 - smooth(6, 20, r * x.u))
        let glow = face.color / 255
        let bloom = 0.3 * min(1.4, bright) * min(1, open * 1.6) * (1 - min(1, e.pupil) * 0.6) * (0.6 + 0.4 * facing)

        // the lids; the iris and the lids are never used together: as the iris comes in, the lids draw back fully
        let span = R * 1.2
        let back = 1 - smooth(0.02, 0.2, e.pupil)
        let lidTop = max(0, e.lidTop) * back, lidBottom = max(0, e.lidBottom) * back
        let lidAngle = e.lidAngle * back, lidCurve = e.lidCurve * back
        let yt = -r * 1.04 + lidTop * 2 * r * 1.04
        let yb = r * 1.04 - lidBottom * 2 * r * 1.04
        // lids part way down are the socket's dark; shut, they are metal shutters with a seam where they meet
        let shut = smooth(0.82, 1, lidTop + lidBottom)
        var lidColor = SIMD3<Double>(Palette8.socket)
        if shut > 0.001 {
            let c = Lighting.radiance(palette.dark, SIMD3(0, -0.2, 1))
            let floor = SIMD3<Double>(0.0019, 0.0016, 0.0013)
            lidColor = Lighting.display(floor + (c * 1.1 - floor) * shut)
        }
        var flags = 0.0
        // inward is toward the crest: −x for the eye on the viewer's right
        let slope = tan(max(-0.9, min(0.9, lidAngle))) * -side
        if lidTop > 0.001 || abs(lidAngle) > 0.001 { flags += 1 }
        if lidBottom > 0.001 || lidCurve > 0.001 { flags += 2 }
        let bow = max(0, lidCurve) * r * 0.5
        var seamY = 0.0, seamWidth = 0.0, seamAlpha = 0.0
        var seamColor = SIMD3<Double>(Palette8.ink)
        if shut > 0.3 {
            // the seam between the shut lids: the glow leaks through it while the eye is lit, dark when it is out
            flags += 4
            seamY = min(yt, yb) + abs(yb - yt) / 2
            let leak = min(1, max(0, e.glow - 0.3) * 1.2)
            seamAlpha = smooth(0.3, 0.8, shut)
            if leak > 0.05 {
                let c = face.color
                seamColor = SIMD3(20 + (c.x * 0.85 - 20) * leak, 15 + (c.y * 0.75 - 15) * leak, 18 + (c.z * 0.6 - 18) * leak) / 255
            }
            seamWidth = R * (0.07 - 0.03 * leak)
        }
        let f = { (v: Double) in Float(v) }
        return EyeUniforms(
            axes: SIMD4(f(ax.x), f(ax.y), f(ay.x), f(ay.y)),
            origin: SIMD4(f(o.x), f(o.y), f(R * 2.1), f(R)),
            glow: SIMD4(f(gx), f(gy), f(r), f(e.shape)),
            light: SIMD4(f(min(1, bright)), f(iris), f(corePart), shows ? 1 : 0),
            color: SIMD4(SIMD3<Float>(glow), f(bloom)),
            lids: SIMD4(f(yt), f(yb), f(slope), f(bow)),
            lidColor: SIMD4(SIMD3<Float>(lidColor), f(span)),
            seam: SIMD4(f(seamY), f(seamWidth), f(seamAlpha), f(flags)),
            seamColor: SIMD4(SIMD3<Float>(seamColor), f(r * (0.92 - 0.8 * iris))),
            iris: SIMD4(f(iris * 0.9), f(viewport.x), f(viewport.y), 0)
        )
    }

    private func prepareTargets(width: Int, height: Int, samples: Int) -> Bool {
        if headTexture != nil && targetKey == (width, height, samples) { return true }
        let head = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        head.usage = [.renderTarget, .shaderRead]
        head.storageMode = .private
        headTexture = device.makeTexture(descriptor: head)
        if samples > 1 {
            let ms = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
            ms.textureType = .type2DMultisample
            ms.sampleCount = samples
            ms.usage = .renderTarget
            ms.storageMode = .memoryless
            msaaTexture = device.makeTexture(descriptor: ms)
        } else {
            msaaTexture = nil
        }
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.depthFormat, width: width, height: height, mipmapped: false)
        depth.textureType = samples > 1 ? .type2DMultisample : .type2D
        depth.sampleCount = samples
        depth.usage = .renderTarget
        depth.storageMode = .memoryless
        depthTexture = device.makeTexture(descriptor: depth)
        targetKey = (width, height, samples)
        return headTexture != nil && depthTexture != nil && (samples == 1 || msaaTexture != nil)
    }
}
