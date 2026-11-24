import Foundation

/// Made / attempted in one zone (01 §4.9). `pct` is computed by the server (0–1, 3 decimals, null with no
/// attempts) and decoded as sent; computed here only if a server leaves the key out.
nonisolated struct ShootingSplit: Codable, Hashable, Sendable {
    var made: Int
    var attempts: Int
    var pct: Double?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case made
        case attempts
        case pct
    }

    init(made: Int = 0, attempts: Int = 0) {
        self.made = made
        self.attempts = attempts
        pct = Self.percentage(made: made, attempts: attempts)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        made = try container.decode(Int.self, forKey: .made)
        attempts = try container.decode(Int.self, forKey: .attempts)
        pct = container.contains(.pct)
            ? try container.decodeIfPresent(Double.self, forKey: .pct)
            : Self.percentage(made: made, attempts: attempts)
    }

    /// `round(made / attempts, 3)`, nil with no attempts (schemas.py:391-398).
    static func percentage(made: Int, attempts: Int) -> Double? {
        guard attempts > 0 else { return nil }
        return (Double(made) / Double(attempts) * 1000).rounded() / 1000
    }
}
