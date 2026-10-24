import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Reading rendered frames back from the GPU, for snapshots, tests and contact sheets.
public enum TextureImage {
    /// A `.bgra8Unorm` render target the CPU can read: shared storage, render target and shader read.
    public static func makeReadableTarget(device: any MTLDevice, width: Int, height: Int) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    /// The texture's pixels (premultiplied BGRA, sRGB) as an image. Call after the GPU has finished with it.
    public static func cgImage(from texture: any MTLTexture) -> CGImage? {
        guard texture.pixelFormat == .bgra8Unorm, texture.storageMode != .private else { return nil }
        let w = texture.width, h = texture.height, rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PNG bytes for an image.
    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// An image's pixels as straight (unpremultiplied) RGBA bytes in sRGB, row by row, for comparisons.
    public static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Int(bytes[i + 3])
            guard a > 0 && a < 255 else { continue }
            for c in 0..<3 { bytes[i + c] = UInt8(min(255, (Int(bytes[i + c]) * 255 + a / 2) / a)) }
        }
        return bytes
    }
}
