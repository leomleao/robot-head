// The Iron Giant as a CharacterKit character: a heavy, gentle robot head, a
// dome with a crest, glowing eyes that do the acting, and a hinged jaw that
// smiles and talks. The sim (Sim/) is a step-for-step port of
// src/robot/sim.ts; the renderer (Render/) draws it with Metal.

import CharacterKit
import CoreGraphics
import Metal
import simd

@MainActor
public final class IronGiantCharacter: CharacterRenderer {
    public static let characterID = "iron-giant"

    public let seed: Double
    public let supportedExpressions = Set(CharacterExpression.core)
    public let supportedActions = Set(CharacterAction.core)

    public var state: CharacterState = .idle { didSet { if state != oldValue { changed() } } }
    public var expression: CharacterExpression? { didSet { if expression != oldValue { changed() } } }
    public var speechLevel: Float?
    public var speechSource: (any SpeechLevelSource)?
    public var lookTarget: LookTarget = .pointer
    /// `body` is the shell (default a weathered gunmetal), `eyes` the glow (default a warm white;
    /// angry and defense turn it red, attack pink). `accent` is unused.
    public var palette = CharacterPalette() { didSet { if palette != oldValue { changed() } } }
    public var speed = 1.0 { didSet { if speed != oldValue { changed() } } }
    public var isPaused = false { didSet { if isPaused != oldValue { changed() } } }
    public var showsFloorShadow = true { didSet { if showsFloorShadow != oldValue { changed() } } }
    public var onChange: (@MainActor () -> Void)?

    private let sim: RobotSim
    private var renderer: IronGiantRenderer?
    /// Reduce Motion, as the view last said.
    private var reduceMotion = false
    /// Showing the still pose: paused, speed 0, or Reduce Motion.
    private var still: Bool { isPaused || !(speed > 0) || reduceMotion }
    /// What was last advanced to, for drawing and hit-testing.
    private var pose = RobotPose()
    private var face = FaceRig()
    private let hits = HeadHitTest()

    public required init(seed: Double) {
        self.seed = min(1, max(0, seed.isFinite ? seed : 0))
        sim = RobotSim(seed: self.seed, state: .idle, expression: nil, eye: FaceRig.white)
        pose = sim.pose
        face = sim.face
    }

    /// A character with a random seed.
    public convenience init() {
        self.init(seed: Double.random(in: 0..<1))
    }

    private var eyeColor: SIMD3<Double> {
        palette.eyes.map { SIMD3($0.red, $0.green, $0.blue) * 255 } ?? FaceRig.white
    }

    private var shellColor: SIMD3<Double> {
        palette.body.map { SIMD3($0.red, $0.green, $0.blue) * 255 } ?? Palette.defaultShell
    }

    private func changed() {
        sim.set(state: state, expression: expression, eye: eyeColor)
        onChange?()
    }

    // MARK: Actions

    public var hasPendingActions: Bool { sim.isActing }

    public func play(_ action: CharacterAction, options: ActionOptions) async -> ActionOutcome {
        guard supportedActions.contains(action) else { return .unsupported }
        // a still head has nothing to play it on
        if still { return .completed }
        let hold = options.hold.map { Double($0.components.seconds) + Double($0.components.attoseconds) * 1e-18 }
        let outcome = await withCheckedContinuation { (done: CheckedContinuation<ActionOutcome, Never>) in
            sim.act(action, hold: hold) { done.resume(returning: $0) }
            onChange?()
        }
        return outcome
    }

    public func poke() {
        guard !still else { return }
        sim.poke()
        onChange?()
    }

    // MARK: Driven by the view

    public func framing(forBox box: CGFloat) -> CharacterFraming {
        Frame(box: Double(box)).framing
    }

    public func prepare(device: any MTLDevice) async throws {
        if let renderer, renderer.device === device { return }
        renderer = try await IronGiantRenderer.make(device: device)
    }

    public func advance(by seconds: Double, input: FrameInput) -> Bool {
        reduceMotion = input.reduceMotion
        if still {
            // the state's still pose with its face; an action already playing runs out unseen
            if sim.isActing { sim.update(seconds) }
            pose = restPose[state] ?? RobotPose()
            face = targetFace(state: state, expression: expression, eye: eyeColor)
            return false
        }
        // points are measured from between the eyes at rest, as the TS does
        let frame = Frame(box: Double(input.framing.box))
        let eyes = SIMD2(Double(input.framing.boxOrigin.x) + frame.box / 2,
                         Double(input.framing.boxOrigin.y) + frame.cy - frame.padTop - 0.26 * frame.unit)
        if let p = input.pointer {
            let d = SIMD2(Double(p.x), Double(p.y)) - eyes
            sim.pointer = simd_length(d) < 900 ? d : nil
        } else {
            sim.pointer = nil
        }
        sim.lookAt = input.lookPoint.map { SIMD2(Double($0.x), Double($0.y)) - eyes }
        sim.mouth = (speechLevel ?? speechSource?.speechLevel).map(Double.init)
        sim.update(seconds * speed)
        pose = sim.pose
        face = sim.face
        return true
    }

    public func encode(into target: RenderTarget, commandBuffer: any MTLCommandBuffer) {
        guard let renderer else { return }
        renderer.encode(scene(for: target.framing, scale: Double(target.scale)), into: target.texture, commandBuffer: commandBuffer, quality: target.quality)
    }

    private func scene(for framing: CharacterFraming, scale: Double) -> RenderScene {
        let frame = Frame(box: Double(framing.box))
        var scene = RenderScene(frame: frame)
        scene.origin = SIMD2(Double(framing.boxOrigin.x) - frame.padSide, Double(framing.boxOrigin.y) - frame.padTop)
        scene.scale = scale
        scene.pose = pose
        scene.face = face
        scene.shell = shellColor
        scene.shadow = showsFloorShadow
        return scene
    }

    public func hitTest(_ point: CGPoint, framing: CharacterFraming) -> Bool {
        let s = scene(for: framing, scale: 1)
        return hits.contains(SIMD2(Double(point.x), Double(point.y)), scene: s)
    }
}
