import Foundation

/// `Game.game_date`: a calendar date with no time and no time zone, sent as `"YYYY-MM-DD"` (01 §1.3,
/// 03 §0). It never goes through the datetime strategy, so no time zone can move it by a day (09 R21);
/// the web builds a local date from the parts the same way (ui.js:194-200).
nonisolated struct GameDate: Codable, Hashable, Sendable, Comparable, CustomStringConvertible, LosslessStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    /// A valid Gregorian date (years 1–9999), or nil.
    init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...CivilCalendar.daysInMonth(year: year, month: month)).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `"2026-01-09"`. A date-time whose date part is first (`"2026-01-09T00:00:00Z"`, which the
    /// server accepts in requests) is read by its date part; anything else is nil.
    init?(_ description: String) {
        let bytes = Array(description.utf8)
        guard bytes.count == 10 || (bytes.count > 10 && [UInt8(ascii: "T"), UInt8(ascii: "t"), UInt8(ascii: " ")].contains(bytes[10])),
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              let year = Self.number(bytes[0..<4]), let month = Self.number(bytes[5..<7]), let day = Self.number(bytes[8..<10])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The calendar day of `date` in `calendar` (e.g. the value of a date picker, in the device's time zone).
    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        self = GameDate(year: year, month: month, day: day) ?? GameDate(uncheckedYear: 1970, month: 1, day: 1)
    }

    private init(uncheckedYear year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = GameDate(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a date such as 2026-01-09.")
        }
        self = date
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// `"2026-01-09"`, the wire form.
    var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (lhs: GameDate, rhs: GameDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// The start of this day in `calendar`'s time zone (for a date picker binding).
    func date(in calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The date for display, e.g. "Jan 9, 2026" with `.abbreviated` in US English: the web's
    /// `{year: "numeric", month: "short", day: "numeric"}` (07 §5.5). The day never shifts with the
    /// device's time zone: the date is formatted at noon UTC in UTC.
    func formatted(_ style: Date.FormatStyle.DateStyle = .abbreviated, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let noon = DateComponents(calendar: calendar, timeZone: .gmt, year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: noon) else { return description }
        let format = Date.FormatStyle(date: style, time: .omitted, locale: locale, calendar: calendar, timeZone: .gmt)
        return date.formatted(format)
    }

    private static func number(_ digits: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for byte in digits {
            guard (0x30...0x39).contains(byte) else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        return value
    }
}
