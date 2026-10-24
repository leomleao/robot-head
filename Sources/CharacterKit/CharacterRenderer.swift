import CoreGraphics
import Metal

/// Where a character looks when nothing in its own life overrides it.
public enum LookTarget: Sendable, Equatable {
    /// Follow the mouse pointer (the view tracks it), where the character's state allows.
    case pointer
    /// Look at a point in global screen coordinates (AppKit points, y up), in every state but sleep.
    case point(CGPoint)
    /// Nothing in particular: the character's own glances.
    case ahead
}

/// A live speech level, 0–1, read once per rendered frame. Reading it must be cheap and safe from
/// the main thread while another thread writes it. ``AudioLevelMeter`` conforms.
public protocol SpeechLevelSource: AnyObject, Sendable {
    var speechLevel: Float { get }
}

/// How much a frame may cost. The pacer picks one; characters decide what each means for them.
public enum QualityTier: Int, CaseIterable, Comparable, Sendable, Codable {
    /// Cheapest: lighter geometry, no multisampling.
    case low
    /// Full look at a lower frame rate.
    case reduced
    /// Everything.
    case full

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Where a character sits in its canvas, in points (y down).
///
/// The *box* is the character at rest: the size a layout gives it. The canvas reaches past the box
/// so motion, glow and the floor's shadow can draw outside it without taking part in layout.
public struct CharacterFraming: Sendable, Equatable {
    /// The resting box's side.
    public var box: CGFloat
    /// The whole canvas.
    public var canvasSize: CGSize
    /// The box's top-left corner in the canvas.
    public var boxOrigin: CGPoint

    public init(box: CGFloat, canvasSize: CGSize, boxOrigin: CGPoint) {
        self.box = box
        self.canvasSize = canvasSize
        self.boxOrigin = boxOrigin
    }
}

/// What the view tells a character about the world each frame.
public struct FrameInput: Sendable, Equatable {
    /// The pointer in canvas points (y down), when the character should follow it; nil otherwise.
    public var pointer: CGPoint?
    /// The ``LookTarget/point(_:)`` target in canvas points (y down); nil when there is none.
    public var lookPoint: CGPoint?
    /// The character's place in the canvas this frame.
    public var framing: CharacterFraming
    /// The system's Reduce Motion setting: characters show a still pose, as for `isPaused`.
    public var reduceMotion: Bool

    public init(pointer: CGPoint? = nil, lookPoint: CGPoint? = nil, framing: CharacterFraming, reduceMotion: Bool = false) {
        self.pointer = pointer
        self.lookPoint = lookPoint
        self.framing = framing
        self.reduceMotion = reduceMotion
    }
}

/// Where and how to draw one frame.
public struct RenderTarget {
    /// The texture to draw into: `.bgra8Unorm`, sRGB-encoded, premultiplied alpha. The character
    /// clears it to transparent first.
    public var texture: any MTLTexture
    /// Pixels per point.
    public var scale: CGFloat
    public var framing: CharacterFraming
    public var quality: QualityTier

    public init(texture: any MTLTexture, scale: CGFloat, framing: CharacterFraming, quality: QualityTier) {
        self.texture = texture
        self.scale = scale
        self.framing = framing
        self.quality = quality
    }
}

/// A character: what Buddy controls, and what ``CharacterView`` draws.
///
/// The control half (state, expression, actions, speech, gaze, looks) is what apps use. The render
/// half (`framing` to `hitTest`) is driven by ``CharacterView`` and ``OffscreenRenderer``; apps
/// rarely call it. A character never owns a view or a window.
@MainActor
public protocol CharacterRenderer: AnyObject {
    /// A stable id for data that names a character, such as `"iron-giant"`.
    static var characterID: String { get }

    /// `seed`, 0–1, offsets the character's blinks and glances so two of them don't move in unison.
    init(seed: Double)

    /// ``CharacterExpression/core`` plus any expressions of the character's own.
    var supportedExpressions: Set<CharacterExpression> { get }
    /// ``CharacterAction/core`` plus any actions of the character's own.
    var supportedActions: Set<CharacterAction> { get }

    // MARK: What it is doing

    var state: CharacterState { get set }
    /// A face over the state's own; nil wears the state's. One the character doesn't know falls back to the state's.
    var expression: CharacterExpression? { get set }
    /// Do something once, over whatever the character is doing. Returns when it ends; a new action
    /// cuts the one playing short (it returns ``ActionOutcome/interrupted``). A still or paused
    /// character has nothing to play it on and returns ``ActionOutcome/completed`` at once.
    @discardableResult
    func play(_ action: CharacterAction, options: ActionOptions) async -> ActionOutcome
    /// A click on the character.
    func poke()

    // MARK: Speech

    /// How loud the character is talking, 0–1, held at a fixed level; nil for none. Each character
    /// shows it its own way (the Iron Giant with its jaw). Set, it replaces the character's own
    /// procedural talking, and it wins over ``speechSource``.
    var speechLevel: Float? { get set }
    /// A live level, read every frame, such as an ``AudioLevelMeter`` on the voice's player.
    var speechSource: (any SpeechLevelSource)? { get set }

    // MARK: Gaze

    var lookTarget: LookTarget { get set }

    // MARK: Looks and timing

    var palette: CharacterPalette { get set }
    /// A multiplier on every animation's speed. 0 holds the still pose.
    var speed: Double { get set }
    /// Hold the state's still pose.
    var isPaused: Bool { get set }
    var showsFloorShadow: Bool { get set }
    /// 0–1, fixed at init.
    var seed: Double { get }

    // MARK: Driven by the view

    /// Called when something changed that a still character must redraw for (state, expression,
    /// palette, pause). The view sets it.
    var onChange: (@MainActor () -> Void)? { get set }
    /// The canvas a resting box of `box` points needs, and where the box sits in it.
    func framing(forBox box: CGFloat) -> CharacterFraming
    /// Compile pipelines and upload geometry for `device`. Drawing waits until it returns.
    func prepare(device: any MTLDevice) async throws
    /// Move the character on by `seconds` of wall-clock time (the character applies ``speed``).
    /// Returns false when nothing is moving, so the view can stop drawing until ``onChange``.
    func advance(by seconds: Double, input: FrameInput) -> Bool
    /// Encode one frame into `target`.
    func encode(into target: RenderTarget, commandBuffer: any MTLCommandBuffer)
    /// Whether `point` (canvas points, y down) is on the character as last advanced.
    func hitTest(_ point: CGPoint, framing: CharacterFraming) -> Bool
    /// Whether an action is playing, so the view keeps time moving while it isn't drawing and
    /// `play` returns.
    var hasPendingActions: Bool { get }
}

public extension CharacterRenderer {
    @discardableResult
    func play(_ action: CharacterAction) async -> ActionOutcome {
        await play(action, options: ActionOptions())
    }
}
