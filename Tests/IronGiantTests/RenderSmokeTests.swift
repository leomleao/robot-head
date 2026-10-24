import CharacterKit
import CoreGraphics
import Foundation
import Metal
import Testing
@testable import IronGiant

/// Renders a few hand-made scenes; set IRONGIANT_RENDER_DIR to keep the PNGs for a look.
@Suite struct RenderSmokeTests {
    static func render(_ scene: RenderScene, quality: QualityTier = .full) async throws -> CGImage {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try await IronGiantRenderer.make(device: device)
        let w = Int((scene.frame.width * scene.scale).rounded()), h = Int((scene.frame.height * scene.scale).rounded())
        let target = try #require(TextureImage.makeReadableTarget(device: device, width: w, height: h))
        let queue = try #require(device.makeCommandQueue())
        let cb = try #require(queue.makeCommandBuffer())
        renderer.encode(scene, into: target, commandBuffer: cb, quality: quality)
        cb.commit()
        await cb.completed()
        #expect(cb.status == .completed)
        return try #require(TextureImage.cgImage(from: target))
    }

    static func keep(_ image: CGImage, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["IRONGIANT_RENDER_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? TextureImage.png(image)?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    @Test func neutralHeadDrawsAndIsTransparentAroundIt() async throws {
        var scene = RenderScene(frame: Frame(box: 240))
        scene.pose = RobotPose(yaw: -0.1, pitch: 0.02, roll: 0.02)
        let image = try await Self.render(scene)
        Self.keep(image, "neutral")
        #expect(image.width == 484 && image.height == 608)
        let px = try #require(TextureImage.rgba(image))
        // a corner is clear; the middle of the head is not
        #expect(px[3] == 0)
        let mid = ((image.height / 2) * image.width + image.width / 2) * 4
        #expect(px[mid + 3] == 255)
    }

    @Test func variety() async throws {
        var happy = RenderScene(frame: Frame(box: 240))
        happy.face.left = EyeRig(lidTop: 0.28, lidBottom: 0.3, lidCurve: 0.5)
        happy.face.right = happy.face.left
        happy.face.jawSmile = 1
        happy.face.jawOpen = 0.2
        happy.face.roll = 0.14
        happy.face.pitch = -0.05
        Self.keep(try await Self.render(happy), "happy")

        var defense = RenderScene(frame: Frame(box: 240))
        defense.face.left = EyeRig(glow: 1.4, pupil: 0.82)
        defense.face.right = defense.face.left
        defense.face.color = [255, 38, 24]
        defense.face.jawSmile = 0
        defense.face.jawOpen = 0.02
        Self.keep(try await Self.render(defense), "defense")

        var asleep = RenderScene(frame: Frame(box: 240))
        asleep.face.left = EyeRig(lidTop: 0.56, lidBottom: 0.46, glow: 0.1)
        asleep.face.right = asleep.face.left
        asleep.face.jawSmile = 0
        asleep.face.jawOpen = 0
        asleep.pose = RobotPose(yaw: 0.05, pitch: -0.3 - 0.22, roll: 0.1 + 0.1)
        Self.keep(try await Self.render(asleep), "asleep")

        var turned = RenderScene(frame: Frame(box: 240))
        turned.pose = RobotPose(yaw: 0.6, pitch: 0.15, roll: -0.1, lift: 0.1)
        turned.face.jawOpen = 0.7
        Self.keep(try await Self.render(turned), "turned")
        Self.keep(try await Self.render(turned, quality: .low), "turned-low")

        var small = RenderScene(frame: Frame(box: 96))
        small.pose = RobotPose(yaw: -0.1, pitch: 0.02, roll: 0.02)
        Self.keep(try await Self.render(small), "small")
    }
}
