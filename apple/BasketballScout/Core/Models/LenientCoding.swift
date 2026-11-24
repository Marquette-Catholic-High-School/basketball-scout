import Foundation

// Decoding helpers for the server's unconstrained floats.
//
// pydantic writes NaN and ±Infinity as JSON `null`, even in fields the schema says are never null
// (01 §1.4, 09 C7). Only floats without a `ge`/`gt` bound can carry one (bounded ones reject NaN on the
// server): in the analysis `t`, `start_t`, `end_t`, `confidence`, `match_confidence`, `match_score`,
// `ball_coverage`, `jersey_match_rate`, vote weights and points, and in a calibration its matrix and
// `reprojection_error_ft`. These helpers read such a `null` (or a missing key) as `.nan`, so one bad
// number cannot fail a multi-megabyte analysis (09 R22), and write a non-finite number back as `null`,
// so a decoded value re-encodes to what the server sent.

nonisolated extension KeyedDecodingContainer {
    /// A float the server never sends as null except for NaN/±Infinity: `null` or a missing key → `.nan`.
    func decodeLenientDouble(forKey key: Key) throws -> Double {
        try decodeIfPresent(Double.self, forKey: key) ?? .nan
    }

    /// `{string: float}` (e.g. `TrackAssignment.votes`) whose values may be `null` (→ `.nan`).
    /// A missing key is an empty dictionary.
    func decodeLenientDoubleDictionary(forKey key: Key) throws -> [String: Double] {
        let values = try decodeIfPresent([String: Double?].self, forKey: key) ?? [:]
        return values.mapValues { $0 ?? .nan }
    }

    /// `[[float]]` (a calibration matrix) whose numbers may be `null` (→ `.nan`).
    func decodeLenientDoubleMatrix(forKey key: Key) throws -> [[Double]] {
        let rows = try decode([[Double?]].self, forKey: key)
        return rows.map { row in row.map { $0 ?? .nan } }
    }
}

nonisolated extension KeyedEncodingContainer {
    /// Writes a finite number as is and NaN/±Infinity as `null`, as the server does.
    mutating func encodeLenientDouble(_ value: Double, forKey key: Key) throws {
        if value.isFinite { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }

    /// Writes `{string: float}` with non-finite values as `null`.
    mutating func encodeLenientDoubleDictionary(_ values: [String: Double], forKey key: Key) throws {
        try encode(values.mapValues { $0.isFinite ? Optional($0) : nil }, forKey: key)
    }

    /// Writes `[[float]]` with non-finite numbers as `null`.
    mutating func encodeLenientDoubleMatrix(_ rows: [[Double]], forKey key: Key) throws {
        try encode(rows.map { row in row.map { $0.isFinite ? Optional($0) : nil } }, forKey: key)
    }
}
