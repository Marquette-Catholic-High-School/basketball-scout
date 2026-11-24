import Foundation

/// The JSON coders every area uses for the server's bodies.
///
/// - Keys: models carry explicit `CodingKeys` with the exact snake_case keys; no key strategy is set,
///   because `.convertFromSnakeCase` would rewrite the keys of free-form objects (09 B12).
/// - Dates: `ScoutTimestamp` (UTC `Z`, with or without a fraction; 09 R21). `game_date` is a `GameDate`
///   (a plain `YYYY-MM-DD` string) and `lease_expires_at` a `Double`, so neither goes through the date
///   strategy.
/// - Output: compact, sorted keys (stable request bodies for tests), slashes not escaped (video links).
///
/// Both functions return a new coder on every call; decoding can run on any thread (large analyses
/// should be decoded off the main actor, 09 R27).
nonisolated enum ScoutJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ScoutTimestamp.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 date-time such as 2026-11-11T19:53:10.180892Z.")
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ScoutTimestamp.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Decodes `type` from `data` with `decoder()`.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    /// Encodes `value` with `encoder()`.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }
}
