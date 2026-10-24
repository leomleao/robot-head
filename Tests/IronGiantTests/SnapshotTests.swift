import CharacterKit
import CoreGraphics
import Foundation
import Testing
@testable import IronGiant

/// Visual regression: the Metal renders against baselines in Snapshots/, at 1×. The stills are the
/// web references' scenes; the motion snapshots step the (deterministic) sim to poses the stills
/// never reach: a turned head, an open jaw, a poke, red eyes coming in.
///
/// A missing baseline is recorded and the test fails once, to be looked at; IRONGIANT_RECORD=1
/// re-records them all.
@MainActor
@Suite(.serialized) struct SnapshotTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Snapshots")
    static let record = ProcessInfo.processInfo.environment["IRONGIANT_RECORD"] == "1"
    /// GPUs may round a little differently; a real change is far beyond these.
    static let maxMean = 0.6
    static let maxLarge = 0.003

    func check(_ image: CGImage, _ name: String) throws {
        let url = Self.directory.appendingPathComponent(name + ".png")
        guard !Self.record, let baseline = ImageCompare.load(url) else {
            try ImageCompare.save(image, to: url)
            Issue.record("recorded \(name).png; check it and run again")
            return
        }
        let r = try #require(ImageCompare.compare(baseline, image), "\(name): size changed")
        #expect(r.mean < Self.maxMean && r.large < Self.maxLarge, "\(name): mean \(r.mean), \(r.large * 100)% of pixels differ")
    }

    @Test func stills() async throws {
        let renderer = try OffscreenRenderer()
        for entry in try ParityTests.manifest().files {
            let image = try await ParityTests.render(entry.params, renderer: renderer)
            let small = try #require(Self.half(image))
            try check(small, (entry.file as NSString).deletingPathExtension)
        }
    }

    /// Each scene: what to do, then how long to run at 60 fps before the snapshot.
    @Test func motion() async throws {
        let renderer = try OffscreenRenderer()
        let framing = IronGiantCharacter(seed: 0).framing(forBox: 240)
        typealias Scene = (name: String, seconds: Double, setUp: (IronGiantCharacter) -> Void)
        let scenes: [Scene] = [
            ("motion-speaking", 2.3, { $0.state = .speaking }),
            ("motion-searching", 1.4, { $0.state = .searching }),
            ("motion-happy-hop", 0.35, { $0.state = .happy }),
            ("motion-poke", 0.3, { $0.poke() }),
            ("motion-defense-coming", 0.15, { c in Task { await c.play(.defense) } }),
            ("motion-mouth-open", 0.5, { $0.speechLevel = 0.9 }),
            ("motion-low-tier", 1.4, { $0.state = .searching }),
        ]
        for scene in scenes {
            let c = IronGiantCharacter(seed: 0.42)
            scene.setUp(c)
            await Task.yield()
            for _ in 0..<Int(scene.seconds * 60) {
                _ = c.advance(by: 1.0 / 60, input: FrameInput(framing: framing))
            }
            let quality: QualityTier = scene.name.hasSuffix("low-tier") ? .low : .full
            let image = try await renderer.image(of: c, box: 240, scale: 1, quality: quality)
            try check(image, scene.name)
        }
    }

    /// Half size, as the baselines are kept at 1×.
    static func half(_ image: CGImage) -> CGImage? {
        let w = image.width / 2, h = image.height / 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
