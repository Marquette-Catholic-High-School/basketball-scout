import Foundation

/// One field of a PATCH body, with the three states the server tells apart (01 §4.2 GameUpdate,
/// 05 §4.6 RosterPlayerPatch, 09 R26): only keys that are present are applied, so "leave it alone"
/// and "set it to null" are different requests.
///
/// - `.unset`: the key is left out of the body (the field keeps its value).
/// - `.null`: the key is sent as JSON `null` (the field is cleared).
/// - `.value(x)`: the key is sent with `x`.
///
/// Inside a keyed container (every request struct) `.unset` writes nothing and a missing key decodes as
/// `.unset`; the container overloads below make this work for hand-written and synthesized `Codable`
/// alike. Request types decide per field what `.null` means where the server refuses null (see
/// `GameUpdate` and `RosterPlayerPatch`).
nonisolated enum Patch<Wrapped> {
    case unset
    case null
    case value(Wrapped)

    /// `.value(x)` for a value, `.null` for nil: "set it, or clear it".
    init(_ optional: Wrapped?) {
        if let optional { self = .value(optional) } else { self = .null }
    }

    var isUnset: Bool {
        if case .unset = self { return true }
        return false
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The new value when this is `.value(x)`; nil for `.unset` and `.null`.
    var valueIfSet: Wrapped? {
        if case .value(let value) = self { return value }
        return nil
    }

    /// Applies the patch to a current value: `.unset` keeps it, `.null` clears it, `.value` replaces it.
    func applied(to current: Wrapped?) -> Wrapped? {
        switch self {
        case .unset: current
        case .null: nil
        case .value(let value): value
        }
    }
}

nonisolated extension Patch: Sendable where Wrapped: Sendable {}
nonisolated extension Patch: Equatable where Wrapped: Equatable {}
nonisolated extension Patch: Hashable where Wrapped: Hashable {}

nonisolated extension Patch: Encodable where Wrapped: Encodable {
    /// Encodes `.null` as `null` and `.value` as the value. `.unset` has no single-value form (it means
    /// "no key at all"), so encoding it outside a keyed container throws.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .unset:
            throw EncodingError.invalidValue(self, EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "Patch.unset can only be encoded as a field of a keyed container, where it is left out."))
        case .null:
            try container.encodeNil()
        case .value(let value):
            try container.encode(value)
        }
    }
}

nonisolated extension Patch: Decodable where Wrapped: Decodable {
    /// `null` decodes as `.null`, anything else as `.value`. A missing key (keyed containers) is `.unset`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else {
            self = .value(try container.decode(Wrapped.self))
        }
    }
}

nonisolated extension KeyedEncodingContainer {
    /// Writes nothing for `.unset`, `null` for `.null`, the value for `.value`.
    mutating func encode<T: Encodable>(_ patch: Patch<T>, forKey key: Key) throws {
        switch patch {
        case .unset: break
        case .null: try encodeNil(forKey: key)
        case .value(let value): try encode(value, forKey: key)
        }
    }
}

nonisolated extension KeyedDecodingContainer {
    /// A missing key is `.unset`, `null` is `.null`, anything else `.value`.
    func decode<T: Decodable>(_ type: Patch<T>.Type, forKey key: Key) throws -> Patch<T> {
        guard contains(key) else { return .unset }
        if try decodeNil(forKey: key) { return .null }
        return .value(try decode(T.self, forKey: key))
    }
}
