import CoreGraphics
import Metal

/// Renders any character to an image, without a window: for snapshots, tests and contact sheets.
@MainActor
public final class OffscreenRenderer {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private var prepared: Set<ObjectIdentifier> = []

    public enum Failure: Error {
        case noDevice
        case noTarget
        case gpu(String)
    }

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw Failure.noDevice }
        self.device = device
        self.queue = queue
    }

    /// The character's canvas for a resting box of `box` points, at `scale` pixels per point, after
    /// advancing it by `seconds` (0 draws it as it is now).
    public func image(of character: any CharacterRenderer, box: CGFloat, scale: CGFloat = 2, quality: QualityTier = .full, advancing seconds: Double = 0, input: FrameInput? = nil) async throws -> CGImage {
        let id = ObjectIdentifier(character)
        if !prepared.contains(id) {
            try await character.prepare(device: device)
            prepared.insert(id)
        }
        let framing = character.framing(forBox: box)
        _ = character.advance(by: seconds, input: input ?? FrameInput(framing: framing))
        let w = Int((framing.canvasSize.width * scale).rounded()), h = Int((framing.canvasSize.height * scale).rounded())
        guard let target = TextureImage.makeReadableTarget(device: device, width: w, height: h),
              let cb = queue.makeCommandBuffer() else { throw Failure.noTarget }
        character.encode(into: RenderTarget(texture: target, scale: scale, framing: framing, quality: quality), commandBuffer: cb)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            cb.addCompletedHandler { _ in done.resume() }
            cb.commit()
        }
        if let error = cb.error { throw Failure.gpu(String(describing: error)) }
        guard let image = TextureImage.cgImage(from: target) else { throw Failure.noTarget }
        return image
    }
}
