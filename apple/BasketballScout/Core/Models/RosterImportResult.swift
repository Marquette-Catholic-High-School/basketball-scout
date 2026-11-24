import Foundation

/// Answer of `POST /api/games/{id}/rosters/{side}/import` (multipart `file` + `mode` form field;
/// 01 §4.5, 05 §4.4, §5.6). The import is already saved.
///
/// `imported` counts player rows read from the file (added and updated together); `warnings` are sentences
/// that may contain player names (show them, never log them).
nonisolated struct RosterImportResult: Codable, Hashable, Sendable {
    /// The roster after the import.
    var roster: Roster
    var imported: Int
    /// Free-form objects; documented as `{"row": Int (1-based file row), "reason": String}`.
    var skippedRows: [SkippedRow]
    var warnings: [String]
    /// Canonical field (`jersey`, `name`, `first_name`, `last_name`, `suffix`, `position`, `grade`, `height`,
    /// `notes`, `fastscout_name`) → header text in the file, or `"column N"` for a file without a header.
    var detectedColumns: [String: String]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case roster
        case imported
        case skippedRows = "skipped_rows"
        case warnings
        case detectedColumns = "detected_columns"
    }

    init(roster: Roster, imported: Int, skippedRows: [SkippedRow] = [], warnings: [String] = [], detectedColumns: [String: String] = [:]) {
        self.roster = roster
        self.imported = imported
        self.skippedRows = skippedRows
        self.warnings = warnings
        self.detectedColumns = detectedColumns
    }

    /// One skipped file row. The server sends a free-form object, so every key is kept in `fields`; `row`
    /// and `reason` read the documented ones.
    nonisolated struct SkippedRow: Codable, Hashable, Sendable {
        var fields: [String: JSONValue]

        init(fields: [String: JSONValue]) {
            self.fields = fields
        }

        init(row: Int, reason: String) {
            fields = ["row": .number(Double(row)), "reason": .string(reason)]
        }

        init(from decoder: any Decoder) throws {
            fields = try decoder.singleValueContainer().decode([String: JSONValue].self)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(fields)
        }

        /// 1-based file row (the Excel row number for `.xlsx`).
        var row: Int? { fields["row"]?.intValue }

        /// E.g. `"missing jersey number"`, `"invalid jersey number 'X'"`.
        var reason: String? { fields["reason"]?.stringValue }

        /// "Row 3: invalid jersey number 'X'" as the web lists them (roster.js:255, 05 §7.3):
        /// `Row ${row ?? "?"}: ${reason ?? "not a player row"}`, so a malformed row still reads as a sentence.
        var displayText: String {
            "Row \(Self.text(of: fields["row"]) ?? "?"): \(Self.text(of: fields["reason"]) ?? "not a player row")"
        }

        /// A value as JavaScript's template literal writes it; nil for a missing or null value (`??`).
        private static func text(of value: JSONValue?) -> String? {
            switch value {
            case nil, .null?:
                return nil
            case .string(let text)?:
                return text
            case .number(let number)?:
                if number.isFinite, number.rounded() == number, abs(number) < 1e15 { return String(Int(number)) }
                return String(number)
            case .bool(let flag)?:
                return flag ? "true" : "false"
            case .array(let items)?:
                return items.map { text(of: $0) ?? "" }.joined(separator: ",")
            case .object?:
                return "[object Object]"
            }
        }
    }

    /// "Columns used" pairs in a stable order: the documented columns first (the web's labels), then any
    /// other key, raw (05 §7.3).
    var columnsUsed: [(label: String, header: String)] {
        let documented = Labels.importColumnOrder.filter { detectedColumns[$0] != nil }
        let others = detectedColumns.keys.filter { !Labels.importColumnOrder.contains($0) }.sorted()
        return (documented + others).compactMap { key in
            detectedColumns[key].map { (Labels.importColumnLabel(for: key), $0) }
        }
    }
}
