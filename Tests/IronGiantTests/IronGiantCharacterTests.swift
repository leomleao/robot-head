import CharacterKit
import CoreGraphics
import Testing
@testable import IronGiant

@MainActor
@Suite struct IronGiantCharacterTests {
    let framing = IronGiantCharacter(seed: 0).framing(forBox: 240)

    func run(_ c: IronGiantCharacter, seconds: Double, input: FrameInput? = nil) async {
        for _ in 0..<Int(seconds * 60) {
            _ = c.advance(by: 1.0 / 60, input: input ?? FrameInput(framing: framing))
            await Task.yield()
        }
    }

    @Test func unknownActionsAreUnsupported() async {
        let c = IronGiantCharacter(seed: 0.3)
        #expect(await c.play("compact") == .unsupported)
    }

    @Test func aStillCharacterCompletesAtOnce() async {
        let c = IronGiantCharacter(seed: 0.3)
        c.isPaused = true
        #expect(await c.play(.nod) == .completed)
        c.isPaused = false
        c.speed = 0
        #expect(await c.play(.nod) == .completed)
    }

    @Test func aNewActionInterruptsTheLast() async {
        let c = IronGiantCharacter(seed: 0.3)
        let nod = Task { await c.play(.nod) }
        await Task.yield()
        await run(c, seconds: 0.2)
        #expect(c.hasPendingActions)
        let shake = Task { await c.play(.shake) }
        await run(c, seconds: 0.1)
        #expect(await nod.value == .interrupted)
        await run(c, seconds: 2)
        #expect(await shake.value == .completed)
        #expect(!c.hasPendingActions)
    }

    @Test func defenseHoldsForTheGivenTime() async {
        let c = IronGiantCharacter(seed: 0.3)
        var done = false
        let t = Task { _ = await c.play(.defense, options: ActionOptions(hold: .milliseconds(500))); done = true }
        await Task.yield()
        // red for the hold, then the 0.25 s way back to white
        await run(c, seconds: 0.6)
        #expect(!done)
        await run(c, seconds: 0.3)
        await t.value
        #expect(done)
    }

    @Test func advanceReportsMotion() {
        let c = IronGiantCharacter(seed: 0.3)
        #expect(c.advance(by: 1.0 / 60, input: FrameInput(framing: framing)))
        #expect(!c.advance(by: 1.0 / 60, input: FrameInput(framing: framing, reduceMotion: true)))
        c.isPaused = true
        #expect(!c.advance(by: 1.0 / 60, input: FrameInput(framing: framing)))
    }

    @Test func changesAreAnnounced() {
        let c = IronGiantCharacter(seed: 0.3)
        var changes = 0
        c.onChange = { changes += 1 }
        c.state = .thinking
        c.state = .thinking
        c.expression = .happy
        c.palette.eyes = RGBColor(hex: "#bfe3ff")
        #expect(changes == 3)
    }

    @Test func hitTestingFollowsTheHead() {
        let c = IronGiantCharacter(seed: 0.3)
        c.isPaused = true
        _ = c.advance(by: 0, input: FrameInput(framing: framing))
        let mid = CGPoint(x: framing.boxOrigin.x + 120, y: framing.boxOrigin.y + 120)
        #expect(c.hitTest(mid, framing: framing))
        // the box's top corners are past the dome; under the chin is the floor
        #expect(!c.hitTest(CGPoint(x: framing.boxOrigin.x + 4, y: framing.boxOrigin.y + 4), framing: framing))
        #expect(!c.hitTest(CGPoint(x: framing.boxOrigin.x + 120, y: framing.boxOrigin.y + 250), framing: framing))
    }

    /// The hit-test agrees with what is drawn, but for a band at the outline (the ink, antialiasing).
    @Test(arguments: [CharacterState.idle, .thinking, .sleeping])
    func hitTestingMatchesTheDrawnSilhouette(_ state: CharacterState) async throws {
        let c = IronGiantCharacter(seed: 0.3)
        c.state = state
        c.expression = state == .idle ? .joyful : nil
        c.isPaused = true
        let image = try await OffscreenRenderer().image(of: c, box: 240, scale: 1)
        let px = try #require(TextureImage.rgba(image))
        var wrong = 0, total = 0
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let alpha = px[(y * image.width + x) * 4 + 3]
                // skip the outline band and the shadow (dark, partly transparent)
                guard alpha == 255 || alpha == 0 else { continue }
                let i = (y * image.width + x) * 4
                // the ink (20, 15, 18) is drawn past the mesh: leave it out, inside and out
                if alpha == 255 && px[i] <= 22 && px[i + 1] <= 17 && px[i + 2] <= 20 { continue }
                let drawn = alpha == 255
                total += 1
                if drawn != c.hitTest(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), framing: framing) { wrong += 1 }
            }
        }
        #expect(Double(wrong) / Double(total) < 0.01, "\(wrong) of \(total) samples disagree")
    }

    @Test func registersById() {
        CharacterRegistry.register(IronGiantCharacter.self)
        #expect(CharacterRegistry.make("iron-giant", seed: 0.5) is IronGiantCharacter)
    }
}
