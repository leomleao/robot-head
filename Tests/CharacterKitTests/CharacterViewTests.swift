import AppKit
import Metal
import Testing
@testable import CharacterKit

/// A character with a round silhouette that fills its box, and a canvas 20% taller than the box.
@MainActor
final class StubCharacter: CharacterRenderer {
    static let characterID = "stub"
    let seed: Double
    init(seed: Double) { self.seed = seed }

    var supportedExpressions = Set(CharacterExpression.core)
    var supportedActions = Set(CharacterAction.core)
    var state = CharacterState.idle { didSet { onChange?() } }
    var expression: CharacterExpression?
    var speechLevel: Float?
    var speechSource: (any SpeechLevelSource)?
    var lookTarget = LookTarget.pointer
    var palette = CharacterPalette()
    var speed = 1.0
    var isPaused = false
    var showsFloorShadow = true
    var onChange: (@MainActor () -> Void)?
    var hasPendingActions: Bool { false }
    var pokes = 0
    var advanced: [FrameInput] = []

    func play(_ action: CharacterAction, options: ActionOptions) async -> ActionOutcome { .completed }
    func poke() { pokes += 1 }
    func framing(forBox box: CGFloat) -> CharacterFraming {
        CharacterFraming(box: box, canvasSize: CGSize(width: box, height: box * 1.2), boxOrigin: CGPoint(x: 0, y: box * 0.2))
    }
    func prepare(device: any MTLDevice) async throws {}
    func advance(by seconds: Double, input: FrameInput) -> Bool {
        advanced.append(input)
        return !isPaused
    }
    func encode(into target: RenderTarget, commandBuffer: any MTLCommandBuffer) {}
    func hitTest(_ point: CGPoint, framing: CharacterFraming) -> Bool {
        let c = CGPoint(x: framing.boxOrigin.x + framing.box / 2, y: framing.boxOrigin.y + framing.box / 2)
        return hypot(point.x - c.x, point.y - c.y) <= framing.box / 2
    }
}

@MainActor
@Suite struct CharacterViewTests {
    @Test func fitsTheLargestBoxAndCentresIt() {
        let view = CharacterView(character: StubCharacter(seed: 0), device: nil)
        view.setFrameSize(NSSize(width: 300, height: 240))
        let f = view.framing
        // 240 tall holds a 200 box (canvas 200 × 240), centred across 300
        #expect(f.box == 200)
        #expect(f.canvasSize == CGSize(width: 300, height: 240))
        #expect(f.boxOrigin == CGPoint(x: 50, y: 40))
        view.preferredBox = 100
        #expect(view.framing.box == 100)
        #expect(CharacterView.canvasSize(for: view.character, box: 100) == CGSize(width: 100, height: 120))
    }

    @Test func hitTestingFollowsTheSilhouetteWithYUp() {
        let view = CharacterView(character: StubCharacter(seed: 0), device: nil)
        view.setFrameSize(NSSize(width: 200, height: 240))
        view.hitSlop = 0
        // the box is the bottom 200 points (y up), its circle centred at (100, 100)
        #expect(view.containsCharacter(at: NSPoint(x: 100, y: 100)))
        #expect(view.containsCharacter(at: NSPoint(x: 100, y: 195)))
        #expect(!view.containsCharacter(at: NSPoint(x: 100, y: 230)))
        #expect(!view.containsCharacter(at: NSPoint(x: 5, y: 5)))
        view.hitSlop = 8
        #expect(view.containsCharacter(at: NSPoint(x: 100, y: 205)))
    }

    @Test func clicksOffTheSilhouetteFallThrough() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 240))
        let view = CharacterView(character: StubCharacter(seed: 0), device: nil)
        view.frame = host.bounds
        host.addSubview(view)
        #expect(view.hitTest(NSPoint(x: 100, y: 100)) === view)
        #expect(view.hitTest(NSPoint(x: 2, y: 238)) == nil)
        view.isInteractive = false
        #expect(view.hitTest(NSPoint(x: 100, y: 100)) == nil)
    }

    @Test func registryMakesCharactersById() {
        CharacterRegistry.register(StubCharacter.self)
        #expect(CharacterRegistry.registeredIDs.contains("stub"))
        let c = CharacterRegistry.make("stub", seed: 0.25)
        #expect(c?.seed == 0.25)
        #expect(CharacterRegistry.make("nobody", seed: 0) == nil)
    }
}
