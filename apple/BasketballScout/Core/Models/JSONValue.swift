import Foundation

/// Any JSON value: the server's free-form objects `Job.params`, `PipelineInfo.options`, `Play.attrs` and
/// `RosterImportResult.skipped_rows[*]` (01 §1.4, §5), and anything else without a fixed schema.
///
/// - Object keys are kept exactly as sent (09 B12): objects decode through a `[String: JSONValue]`
///   dictionary, whose keys no key-decoding strategy rewrites (`zone_shape` stays `zone_shape`).
/// - Numbers are `Double`. Inside free-form objects JSON does not say int or float, and both arrive
///   (`seed: 25151`, `ocr_noise: 0.15`); integers up to 2^53 are exact. Use `intValue` to read an int.
/// - A non-finite number encodes as `null`, as the server writes NaN (01 §1.4).
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value.")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.isFinite { try container.encode(value) } else { try container.encodeNil() }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Reading values

nonisolated extension JSONValue {
    /// The member `key` of an object; nil for a missing key or when this is not an object.
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    /// The element at `index` of an array; nil when out of range or when this is not an array.
    subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    var isNull: Bool { self == .null }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The number as an `Int` when it is integral and in range (`3` and `3.0` give 3, `3.5` gives nil).
    var intValue: Int? {
        guard case .number(let value) = self, value.rounded(.towardZero) == value else { return nil }
        return Int(exactly: value)
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// JavaScript truthiness, for rules the web writes as `if (value)`, e.g. `job.params?.report`
    /// (jobpanel.js:33): false for `null`, `false`, `0`, NaN and `""`; true for everything else,
    /// including empty arrays and objects.
    var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0 && !value.isNaN
        case .string(let value): !value.isEmpty
        case .array, .object: true
        }
    }
}

// MARK: - Literals (for building request params, e.g. `["coach_focus": "We play a 2-3 zone"]`)

nonisolated extension JSONValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self = .null }
}

nonisolated extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

nonisolated extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .number(Double(value)) }
}

nonisolated extension JSONValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .number(value) }
}

nonisolated extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

nonisolated extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

nonisolated extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
