import CharacterKit
import CoreGraphics
import Foundation
import Testing
@testable import IronGiant

/// The Metal Iron Giant against the TS one: every still in docs/swift-port/reference/web
/// (captured from the web playground's canvas by scripts/swift/capture-web-references.mjs) is
/// rendered here with the same parameters and compared, laid over the same grey.
///
/// Set PARITY_OUT to a directory to get, per image, web | metal | difference ×4, and a report.json.
@MainActor
@Suite(.serialized) struct ParityTests {
    struct Manifest: Decodable {
        struct Entry: Decodable {
            struct Params: Decodable {
                var state: String
                var expression: String?
                var size: Double
                var color: String?
                var eyeColor: String?
                var floorShadow: Bool
            }
            var file: String
            var params: Params
        }
        var files: [Entry]
    }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let references = root.appendingPathComponent("docs/swift-port/reference/web")

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: references.appendingPathComponent("manifest.json")))
    }

    /// The Metal render of one entry, as the TS draws it: paused, at 2×.
    static func render(_ p: Manifest.Entry.Params, renderer: OffscreenRenderer) async throws -> CGImage {
        let c = IronGiantCharacter(seed: 0.5)
        c.state = CharacterState(rawValue: p.state) ?? .idle
        c.expression = p.expression.map(CharacterExpression.init(rawValue:))
        c.palette = CharacterPalette(body: p.color.flatMap(CharacterColor.init(hex:)), eyes: p.eyeColor.flatMap(CharacterColor.init(hex:)))
        c.showsFloorShadow = p.floorShadow
        c.isPaused = true
        return try await renderer.image(of: c, box: p.size, scale: 2)
    }

    /// The bounds every reference must stay within. Most of the difference is antialiasing along
    /// edges and faint shading banding the TS has and the GPU doesn't (see PARITY.md).
    static let maxMean = 2.0
    static let maxLarge = 0.02

    @Test func everyReferenceMatches() async throws {
        let renderer = try OffscreenRenderer()
        let out = ProcessInfo.processInfo.environment["PARITY_OUT"].map { URL(fileURLWithPath: $0) }
        var report: [[String: Any]] = []
        for entry in try Self.manifest().files {
            let web = try #require(ImageCompare.load(Self.references.appendingPathComponent(entry.file)), "\(entry.file)")
            let metal = try await Self.render(entry.params, renderer: renderer)
            #expect(metal.width == web.width && metal.height == web.height, "\(entry.file): size \(metal.width)×\(metal.height) vs \(web.width)×\(web.height)")
            let r = try #require(ImageCompare.compare(web, metal, makeDiff: out != nil), "\(entry.file)")
            #expect(r.mean < Self.maxMean, "\(entry.file): mean difference \(r.mean)")
            #expect(r.large < Self.maxLarge, "\(entry.file): \(r.large * 100)% of pixels differ by more than 24")
            report.append(["file": entry.file, "mean": (r.mean * 100).rounded() / 100, "largePercent": (r.large * 10000).rounded() / 100])
            if let out, let diff = r.diff, let sheet = ImageCompare.sideBySide([web, metal, diff]) {
                try ImageCompare.save(sheet, to: out.appendingPathComponent(entry.file))
                try ImageCompare.save(metal, to: out.appendingPathComponent("metal").appendingPathComponent(entry.file))
            }
        }
        if let out {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: out.appendingPathComponent("report.json"))
        }
    }
}
