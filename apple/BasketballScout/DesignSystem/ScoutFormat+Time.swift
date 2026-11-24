import Foundation

nonisolated extension ScoutFormat {
    // MARK: - Film time and durations

    /// The web's `formatClock`: whole seconds (rounded down) as "m:ss", or "h:mm:ss" from one hour.
    /// Negative, nil or non-finite → "0:00". 75.9 → "1:15", 3725 → "1:02:05", 59.99 → "0:59".
    /// Used for film times (events, plays, shots, the player); there is no game clock.
    static func clock(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(min(seconds, 1e12).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        let ss = secs < 10 ? "0\(secs)" : "\(secs)"
        if hours > 0 {
            let mm = minutes < 10 ? "0\(minutes)" : "\(minutes)"
            return "\(hours):\(mm):\(ss)"
        }
        return "\(minutes):\(ss)"
    }

    /// A film time for VoiceOver: "1 minute, 15 seconds" (same whole seconds as `clock`).
    static func spokenClock(_ seconds: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        let total: Int
        if let seconds, seconds.isFinite, seconds > 0 {
            total = Int(min(seconds, 1e12).rounded(.down))
        } else {
            total = 0
        }
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide)
            .locale(locale)
        return Duration.seconds(total).formatted(style)
    }

    /// The web's `formatDuration` (ETAs, job "running for", film length): rounded seconds as
    /// "45 s", "3 min 20 s" or "1 h 5 min". Negative, nil or non-finite → "–".
    /// 59.6 → "1 min 0 s", 2880 → "48 min 0 s", 4000 → "1 h 6 min".
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return placeholder }
        let s = Int(roundHalfUp(min(seconds, 1e12)))
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min \(s % 60) s" }
        return "\(m / 60) h \(m % 60) min"
    }

    /// The web's `formatAgo` (worker last seen): nil → "never"; under 90 s → "45 s ago"; under
    /// 5400 s → "10 min ago"; else "2 h ago" (each rounded half up). Negative values (impossible
    /// from the server) count as 0; non-finite → "–".
    static func ago(_ seconds: Double?) -> String {
        guard let seconds else { return "never" }
        guard seconds.isFinite else { return placeholder }
        let s = max(0, min(seconds, 1e12))
        if s < 90 { return "\(Int(roundHalfUp(s))) s ago" }
        if s < 5400 { return "\(Int(roundHalfUp(s / 60))) min ago" }
        return "\(Int(roundHalfUp(s / 3600))) h ago"
    }

    /// A past moment measured with the device clock: "just now" under 10 seconds, then the
    /// `ago` wording ("45 s ago", "2 min ago", "3 h ago"); nil → "never". Future dates (clock
    /// skew) count as now (09 R35).
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = max(0, now.timeIntervalSince(date))
        return seconds < 10 ? "just now" : ago(seconds)
    }

    /// The job panel's elapsed time: "running for 3 min 20 s" from `started_at` and the device clock
    /// (clamped at 0, 09 R35); nil when the job has not started.
    static func runningFor(since start: Date?, now: Date = Date()) -> String? {
        guard let start else { return nil }
        return "running for \(duration(max(0, now.timeIntervalSince(start))))"
    }

    // MARK: - Calendar dates and timestamps

    /// The parts of a `game_date` ("YYYY-MM-DD"; only the first 10 characters are read, as the web
    /// does), or nil when a part is missing, zero or not a number.
    static func gameDateComponents(_ isoDate: String?) -> (year: Int, month: Int, day: Int)? {
        guard let isoDate else { return nil }
        let parts = isoDate.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year > 0, month > 0, day > 0
        else { return nil }
        return (year, month, day)
    }

    /// The web's `formatDate`: a calendar date "YYYY-MM-DD" in the device locale's medium style
    /// ("Jan 17, 2026" in en-US). Built in the given time zone and shown in the same one, so the
    /// day never shifts. nil or "" → ""; text that is not a date is returned as it is.
    static func gameDate(
        _ isoDate: String?,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard let isoDate, !isoDate.isEmpty else { return "" }
        guard let parts = gameDateComponents(isoDate),
              calendarDate(year: parts.year, month: parts.month, day: parts.day, timeZone: timeZone) != nil
        else { return isoDate }
        return gameDate(year: parts.year, month: parts.month, day: parts.day, locale: locale, timeZone: timeZone)
    }

    /// `gameDate(_:)` for a date already split into parts (the models' `GameDate`):
    /// `ScoutFormat.gameDate(year: d.year, month: d.month, day: d.day)` → "Jan 17, 2026".
    static func gameDate(
        year: Int,
        month: Int,
        day: Int,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard let date = calendarDate(year: year, month: month, day: day, timeZone: timeZone) else {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return date.formatted(displayStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone))
    }

    /// Noon of a "YYYY-MM-DD" day in `timeZone` (noon keeps the day stable across DST changes).
    /// Out-of-range parts roll over as the web's `new Date(y, m - 1, d)` does ("2026-13-01" is
    /// Jan 1, 2027).
    static func calendarDate(_ isoDate: String?, timeZone: TimeZone = .autoupdatingCurrent) -> Date? {
        guard let parts = gameDateComponents(isoDate) else { return nil }
        return calendarDate(year: parts.year, month: parts.month, day: parts.day, timeZone: timeZone)
    }

    /// Noon of a calendar day in `timeZone`.
    static func calendarDate(year: Int, month: Int, day: Int, timeZone: TimeZone = .autoupdatingCurrent) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return calendar.date(from: components)
    }

    /// The web's `formatDateTime` (report versions): date and time in the device locale and time
    /// zone ("11/11/2026, 10:00:00 AM" in en-US); nil → "".
    static func dateTime(
        _ date: Date?,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard let date else { return "" }
        return date.formatted(displayStyle(date: .numeric, time: .standard, locale: locale, timeZone: timeZone))
    }

    /// A date style in the locale's own calendar and the given time zone.
    private static func displayStyle(
        date: Date.FormatStyle.DateStyle,
        time: Date.FormatStyle.TimeStyle,
        locale: Locale,
        timeZone: TimeZone
    ) -> Date.FormatStyle {
        var calendar = locale.calendar
        calendar.timeZone = timeZone
        return Date.FormatStyle(date: date, time: time, locale: locale, calendar: calendar, timeZone: timeZone)
    }
}
