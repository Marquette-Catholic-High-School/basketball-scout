import Foundation

/// Reads and writes the server's datetimes (`created_at`, `updated_at`, `started_at`, `finished_at`,
/// `generated_at`, calibration and roster times) without `ISO8601DateFormatter` or `.iso8601`.
///
/// The server writes UTC with a `Z` and six fractional digits, leaving the fraction out when it is zero:
/// `2026-11-11T19:53:10.180892Z` and `2026-11-11T10:00:00Z` (01 §1.3, 09 C7). Foundation's parsers
/// disagree about the fraction between OS releases (09 B11), so this is a small, fixed parser that
/// behaves the same on every OS the app supports. It also accepts what a lenient reader should
/// (01 §5, 03 §0): any number of fractional digits (`.` or `,`), `+hh:mm` / `+hhmm` / `+hh` offsets,
/// a lower-case `t`/`z` or a space separator, and a missing zone (read as UTC).
nonisolated enum ScoutTimestamp {
    /// The date for an ISO 8601 date-time string, or nil when it is not one.
    static func date(from text: String) -> Date? {
        var reader = ByteReader(Array(text.utf8))
        guard let year = reader.digits(4), reader.skip("-"),
              let month = reader.digits(2), reader.skip("-"),
              let day = reader.digits(2),
              reader.skipAny(of: ["T", "t", " "]),
              let hour = reader.digits(2), reader.skip(":"),
              let minute = reader.digits(2), reader.skip(":"),
              let second = reader.digits(2)
        else { return nil }

        var fraction = 0.0
        if reader.skipAny(of: [".", ","]) {
            guard let value = reader.fraction() else { return nil }
            fraction = value
        }

        var offsetSeconds = 0
        if reader.skipAny(of: ["Z", "z"]) {
            offsetSeconds = 0
        } else if let sign = reader.sign() {
            guard let offsetHours = reader.digits(2), offsetHours <= 23 else { return nil }
            var offsetMinutes = 0
            if !reader.isAtEnd {
                _ = reader.skip(":")
                guard let minutes = reader.digits(2), minutes <= 59 else { return nil }
                offsetMinutes = minutes
            }
            offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
        }
        guard reader.isAtEnd,
              (1...12).contains(month),
              (1...CivilCalendar.daysInMonth(year: year, month: month)).contains(day),
              hour <= 23, minute <= 59, second <= 59
        else { return nil }

        let days = CivilCalendar.daysFromCivil(year: year, month: month, day: day)
        let unixSeconds = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        // Subtract the reference date in integers first so the fraction keeps as many bits as possible.
        let referenceSeconds = unixSeconds - Int(Date.timeIntervalBetween1970AndReferenceDate)
        return Date(timeIntervalSinceReferenceDate: Double(referenceSeconds) + fraction)
    }

    /// The server's own form for a date: UTC, `Z`, six fractional digits when the microseconds are not
    /// zero and none when they are (`2026-11-11T10:00:00Z`). Rounded to the nearest microsecond, so a
    /// parsed server timestamp writes back exactly as it was read.
    static func string(from date: Date) -> String {
        let micros = Int64((date.timeIntervalSinceReferenceDate * 1_000_000).rounded())
        let (referenceSeconds, fraction) = floorDivide(micros, 1_000_000)
        let unixSeconds = Int(referenceSeconds) + Int(Date.timeIntervalBetween1970AndReferenceDate)
        let (days, secondOfDay) = floorDivide(Int64(unixSeconds), 86_400)
        let (year, month, day) = CivilCalendar.civilFromDays(Int(days))
        let seconds = Int(secondOfDay)
        var text = pad(year, 4) + "-" + pad(month, 2) + "-" + pad(day, 2)
        text += "T" + pad(seconds / 3600, 2) + ":" + pad(seconds % 3600 / 60, 2) + ":" + pad(seconds % 60, 2)
        if fraction != 0 { text += "." + pad(Int(fraction), 6) }
        return text + "Z"
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> (quotient: Int64, remainder: Int64) {
        var quotient = value / divisor
        var remainder = value % divisor
        if remainder < 0 {
            quotient -= 1
            remainder += divisor
        }
        return (quotient, remainder)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(abs(value))
        let padded = String(repeating: "0", count: max(0, width - digits.count)) + digits
        return value < 0 ? "-" + padded : padded
    }

    /// A forward-only reader over the UTF-8 bytes of a timestamp.
    private struct ByteReader {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var isAtEnd: Bool { index == bytes.count }

        /// Exactly `count` ASCII digits as a number.
        mutating func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[index..<(index + count)] {
                guard (0x30...0x39).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            index += count
            return value
        }

        /// One or more ASCII digits read as a fraction of a second (`180892` → 0.180892).
        mutating func fraction() -> Double? {
            var value = 0.0
            var scale = 1.0
            let start = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                if index - start < 9 {
                    scale /= 10
                    value += Double(bytes[index] - 0x30) * scale
                }
                index += 1
            }
            return index > start ? value : nil
        }

        /// +1 for `+`, -1 for `-`, nil for anything else (not consumed).
        mutating func sign() -> Int? {
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "+"): index += 1; return 1
            case UInt8(ascii: "-"): index += 1; return -1
            default: return nil
            }
        }

        mutating func skip(_ character: Unicode.Scalar) -> Bool {
            skipAny(of: [character])
        }

        mutating func skipAny(of characters: [Unicode.Scalar]) -> Bool {
            guard index < bytes.count, characters.contains(where: { UInt8(ascii: $0) == bytes[index] }) else { return false }
            index += 1
            return true
        }
    }
}

/// Proleptic Gregorian calendar arithmetic on plain integers (H. Hinnant's days-from-civil algorithms),
/// used for timestamps and game dates so no time zone or locale can shift a day.
nonisolated enum CivilCalendar {
    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days since 1970-01-01 for a civil date.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let monthIndex = (month + 9) % 12
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The civil date `days` after 1970-01-01.
    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}
