import CharacterKit
import CoreGraphics
import Foundation
import ImageIO

/// Comparing rendered images: both laid over the same grey, then differenced.
enum ImageCompare {
    /// The grey both images are laid over, like the playground's dark stage but lighter, so the ink shows.
    static let background: SIMD3<Double> = [138, 143, 152]

    struct Result {
        /// Mean absolute difference per channel, 0–255.
        var mean: Double
        /// The share of pixels where some channel differs by more than 24.
        var large: Double
        /// The difference, amplified 4×, as an image.
        var diff: CGImage?
    }

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func save(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let png = TextureImage.png(image) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }

    /// The image over the grey, as RGB bytes.
    static func flatten(_ image: CGImage) -> [UInt8]? {
        guard let px = TextureImage.rgba(image) else { return nil }
        var out = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for i in 0..<(image.width * image.height) {
            let a = Double(px[i * 4 + 3]) / 255
            for c in 0..<3 {
                out[i * 3 + c] = UInt8((Double(px[i * 4 + c]) * a + background[c] * (1 - a)).rounded())
            }
        }
        return out
    }

    static func compare(_ a: CGImage, _ b: CGImage, makeDiff: Bool = false) -> Result? {
        guard a.width == b.width, a.height == b.height, let fa = flatten(a), let fb = flatten(b) else { return nil }
        var sum = 0, large = 0
        var diff = makeDiff ? [UInt8](repeating: 255, count: a.width * a.height * 4) : []
        for i in 0..<(a.width * a.height) {
            var most = 0
            for c in 0..<3 {
                let d = abs(Int(fa[i * 3 + c]) - Int(fb[i * 3 + c]))
                sum += d
                most = max(most, d)
                if makeDiff { diff[i * 4 + c] = UInt8(min(255, d * 4)) }
            }
            if most > 24 { large += 1 }
        }
        let n = Double(a.width * a.height)
        var image: CGImage?
        if makeDiff, let space = CGColorSpace(name: CGColorSpace.sRGB),
           let ctx = CGContext(data: &diff, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: a.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            image = ctx.makeImage()
        }
        return Result(mean: Double(sum) / (n * 3), large: Double(large) / n, diff: image)
    }

    /// Images side by side over the grey, with a gap.
    static func sideBySide(_ images: [CGImage]) -> CGImage? {
        let gap = 12, w = images.reduce(gap) { $0 + $1.width + gap }, h = (images.map(\.height).max() ?? 0) + 2 * gap
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: background.x / 255, green: background.y / 255, blue: background.z / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var x = gap
        for im in images {
            ctx.draw(im, in: CGRect(x: x, y: h - gap - im.height, width: im.width, height: im.height))
            x += im.width + gap
        }
        return ctx.makeImage()
    }
}
