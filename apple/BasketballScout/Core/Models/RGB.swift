import Foundation

/// A jersey colour sent as `[r, g, b]` with 0–255 channels (`TeamSummary.color_rgb`, 01 §1.2).
nonisolated struct RGB: Codable, Hashable, Sendable {
    var red: Int
    var green: Int
    var blue: Int

    init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        red = try container.decode(Int.self)
        green = try container.decode(Int.self)
        blue = try container.decode(Int.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(red)
        try container.encode(green)
        try container.encode(blue)
    }

    /// `#rrggbb` with each channel clamped to 0–255, the web's `rgbToCss` (06 §5.1).
    var hexString: String {
        "#" + [red, green, blue].map { channel in
            let clamped = min(255, max(0, channel))
            let hex = String(clamped, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }
}
