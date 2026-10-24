import Foundation

/// A colour in sRGB, each channel 0–1.
public struct RGBColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 0–255 channels.
    public init(red255 r: Int, green255 g: Int, blue255 b: Int) {
        self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// `#rgb` or `#rrggbb` (the `#` is optional); nil for anything else.
    public init?(hex: String) {
        var s = Substring(hex.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 3 || s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        let full = s.count == 3 ? String(s.flatMap { [$0, $0] }) : String(s)
        guard let n = UInt32(full, radix: 16) else { return nil }
        self.init(red255: Int((n >> 16) & 255), green255: Int((n >> 8) & 255), blue255: Int(n & 255))
    }

    /// `#rrggbb`.
    public var hex: String {
        func byte(_ c: Double) -> String {
            let v = Int((min(1, max(0, c)) * 255).rounded())
            return String(v, radix: 16).leftPadded(to: 2)
        }
        return "#" + byte(red) + byte(green) + byte(blue)
    }
}

private extension String {
    func leftPadded(to n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}

/// A character's colours. Every slot is optional: nil takes the character's own default.
public struct CharacterPalette: Hashable, Sendable, Codable {
    /// The body: the Iron Giant's shell, WALL-E's body.
    public var body: RGBColor?
    /// The eyes' glow or lens tint. A character may override it where colour is the point
    /// (the Iron Giant's red eyes in `angry` and `defense`).
    public var eyes: RGBColor?
    /// A third colour, for characters that have one (WALL-E's treads). The Iron Giant ignores it.
    public var accent: RGBColor?

    public init(body: RGBColor? = nil, eyes: RGBColor? = nil, accent: RGBColor? = nil) {
        self.body = body
        self.eyes = eyes
        self.accent = accent
    }
}
