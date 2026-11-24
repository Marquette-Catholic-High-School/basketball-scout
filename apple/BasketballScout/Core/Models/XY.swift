import Foundation

/// Two numbers sent as a JSON array `[x, y]` (the server's `Point` tuple, 01 §1.2): court feet for
/// `court_xy`, `half_court_xy` and court landmarks; video pixels for calibration `px`.
///
/// A coordinate written as `null` (NaN on the server, 01 §1.4) decodes as `.nan` and encodes back as
/// `null`. Extra elements after the first two are ignored.
nonisolated struct XY: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decodeIfPresent(Double.self) ?? .nan
        y = try container.decodeIfPresent(Double.self) ?? .nan
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in [x, y] {
            if value.isFinite { try container.encode(value) } else { try container.encodeNil() }
        }
    }

    /// Both coordinates are finite numbers.
    var isFinite: Bool { x.isFinite && y.isFinite }
}
