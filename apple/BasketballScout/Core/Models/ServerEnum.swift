import Foundation

/// A string enum whose values the server owns and may extend in a newer version (01 §3, 09 R24).
///
/// Every conforming enum has one case per documented raw value plus `unknown(String)`. Decoding never
/// fails on a value this app does not know: it becomes `.unknown(raw)`, and encoding writes the raw value
/// back unchanged, so an unknown value round-trips. Conformers list their documented cases in
/// `knownCases` (in the spec's order) and spell each raw value in `rawValue`; this protocol supplies
/// `init(rawValue:)` and the `Codable` implementation (a plain JSON string).
nonisolated protocol ServerEnum: Codable, Hashable, Sendable, CustomStringConvertible {
    /// The documented cases, in the order the spec lists them.
    static var knownCases: [Self] { get }
    /// The fallback for a raw value this app does not know.
    static func unknown(_ rawValue: String) -> Self
    /// The exact JSON string of this value.
    var rawValue: String { get }
    /// Maps a raw value to its documented case; anything else becomes `.unknown(rawValue)`.
    init(rawValue: String)
}

nonisolated extension ServerEnum {
    init(rawValue: String) {
        self = Self.knownCases.first { $0.rawValue == rawValue } ?? Self.unknown(rawValue)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// False for a value this app does not know (`.unknown(_)`).
    var isKnown: Bool { Self.knownCases.contains(self) }

    /// The raw value, so string interpolation and logs show the wire value.
    var description: String { rawValue }
}
