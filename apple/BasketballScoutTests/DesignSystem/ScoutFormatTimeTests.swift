import Foundation
import Testing
@testable import BasketballScout

/// Expected strings come from the web's `ui.js` run in Node (en-US), unless noted.
@Suite("ScoutFormat times and dates")
struct ScoutFormatTimeTests {
    private let enUS = Locale(identifier: "en_US")
    private let chicago = TimeZone(identifier: "America/Chicago")!

    /// ICU may put a narrow no-break space before AM/PM; compare with plain spaces.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: Clock

    @Test("clock: formatClock examples")
    func clock() {
        #expect(ScoutFormat.clock(75.9) == "1:15")
        #expect(ScoutFormat.clock(3725) == "1:02:05")
        #expect(ScoutFormat.clock(65) == "1:05")
        #expect(ScoutFormat.clock(59.99) == "0:59")
        #expect(ScoutFormat.clock(0) == "0:00")
        #expect(ScoutFormat.clock(3600) == "1:00:00")
        #expect(ScoutFormat.clock(3599.999) == "59:59")
        #expect(ScoutFormat.clock(86399) == "23:59:59")
        #expect(ScoutFormat.clock(360000) == "100:00:00")
        #expect(ScoutFormat.clock(61) == "1:01")
        #expect(ScoutFormat.clock(600.4) == "10:00")
    }

    @Test("clock: negative, nil and invalid show 0:00")
    func clockInvalid() {
        #expect(ScoutFormat.clock(-3) == "0:00")
        #expect(ScoutFormat.clock(nil) == "0:00")
        #expect(ScoutFormat.clock(.nan) == "0:00")
        #expect(ScoutFormat.clock(.infinity) == "0:00")
    }

    @Test("spokenClock reads whole seconds as words")
    func spokenClock() {
        #expect(ScoutFormat.spokenClock(75.9, locale: enUS) == "1 minute, 15 seconds")
        #expect(ScoutFormat.spokenClock(3725, locale: enUS) == "1 hour, 2 minutes, 5 seconds")
        #expect(ScoutFormat.spokenClock(-4, locale: enUS) == "0 seconds")
        #expect(ScoutFormat.spokenClock(nil, locale: enUS) == "0 seconds")
    }

    // MARK: Duration

    @Test("duration: formatDuration examples")
    func duration() {
        #expect(ScoutFormat.duration(200) == "3 min 20 s")
        #expect(ScoutFormat.duration(3900) == "1 h 5 min")
        #expect(ScoutFormat.duration(59.6) == "1 min 0 s")
        #expect(ScoutFormat.duration(2880) == "48 min 0 s")
        #expect(ScoutFormat.duration(4000) == "1 h 6 min")
        #expect(ScoutFormat.duration(0) == "0 s")
        #expect(ScoutFormat.duration(0.4) == "0 s")
        #expect(ScoutFormat.duration(0.5) == "1 s")
        #expect(ScoutFormat.duration(59.4) == "59 s")
        #expect(ScoutFormat.duration(59.5) == "1 min 0 s")
        #expect(ScoutFormat.duration(60) == "1 min 0 s")
        #expect(ScoutFormat.duration(3599) == "59 min 59 s")
        #expect(ScoutFormat.duration(3599.5) == "1 h 0 min")
        #expect(ScoutFormat.duration(3600) == "1 h 0 min")
        #expect(ScoutFormat.duration(86400) == "24 h 0 min")
        #expect(ScoutFormat.duration(45) == "45 s")
        #expect(ScoutFormat.duration(125.5) == "2 min 6 s")
        #expect(ScoutFormat.duration(7322) == "2 h 2 min")
    }

    @Test("duration: negative, nil and invalid show the placeholder")
    func durationInvalid() {
        #expect(ScoutFormat.duration(-1) == "\u{2013}")
        #expect(ScoutFormat.duration(nil) == "\u{2013}")
        #expect(ScoutFormat.duration(.nan) == "\u{2013}")
        #expect(ScoutFormat.duration(.infinity) == "\u{2013}")
    }

    // MARK: Ago and relative

    @Test("ago: formatAgo examples")
    func ago() {
        #expect(ScoutFormat.ago(nil) == "never")
        #expect(ScoutFormat.ago(45) == "45 s ago")
        #expect(ScoutFormat.ago(600) == "10 min ago")
        #expect(ScoutFormat.ago(3.2) == "3 s ago")
        #expect(ScoutFormat.ago(0) == "0 s ago")
        #expect(ScoutFormat.ago(0.4) == "0 s ago")
        #expect(ScoutFormat.ago(0.5) == "1 s ago")
        #expect(ScoutFormat.ago(89.4) == "89 s ago")
        #expect(ScoutFormat.ago(89.5) == "90 s ago")
        #expect(ScoutFormat.ago(90) == "2 min ago")
        #expect(ScoutFormat.ago(119.6) == "2 min ago")
        #expect(ScoutFormat.ago(120.1) == "2 min ago")
        #expect(ScoutFormat.ago(150) == "3 min ago")
        #expect(ScoutFormat.ago(5399) == "90 min ago")
        #expect(ScoutFormat.ago(5400) == "2 h ago")
        #expect(ScoutFormat.ago(7200) == "2 h ago")
    }

    @Test("ago: negative counts as 0, non-finite is unknown")
    func agoEdges() {
        #expect(ScoutFormat.ago(-5) == "0 s ago")
        #expect(ScoutFormat.ago(.nan) == "\u{2013}")
    }

    @Test("relative: just now, then the web's wording; clock skew clamps")
    func relative() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(ScoutFormat.relative(nil, now: now) == "never")
        #expect(ScoutFormat.relative(now, now: now) == "just now")
        #expect(ScoutFormat.relative(now.addingTimeInterval(-9.9), now: now) == "just now")
        #expect(ScoutFormat.relative(now.addingTimeInterval(-10), now: now) == "10 s ago")
        #expect(ScoutFormat.relative(now.addingTimeInterval(-120), now: now) == "2 min ago")
        #expect(ScoutFormat.relative(now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
        #expect(ScoutFormat.relative(now.addingTimeInterval(300), now: now) == "just now")
    }

    @Test("runningFor uses formatDuration and clamps at 0")
    func runningFor() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(ScoutFormat.runningFor(since: nil, now: now) == nil)
        #expect(ScoutFormat.runningFor(since: now.addingTimeInterval(-200), now: now) == "running for 3 min 20 s")
        #expect(ScoutFormat.runningFor(since: now.addingTimeInterval(-3900), now: now) == "running for 1 h 5 min")
        #expect(ScoutFormat.runningFor(since: now.addingTimeInterval(60), now: now) == "running for 0 s")
    }

    // MARK: Game dates

    @Test("gameDate: medium date in the device locale")
    func gameDate() {
        #expect(ScoutFormat.gameDate("2026-01-17", locale: enUS, timeZone: chicago) == "Jan 17, 2026")
        #expect(ScoutFormat.gameDate("2026-03-04", locale: enUS, timeZone: chicago) == "Mar 4, 2026")
        #expect(ScoutFormat.gameDate("2026-12-31", locale: enUS, timeZone: chicago) == "Dec 31, 2026")
        #expect(ScoutFormat.gameDate("2024-02-29", locale: enUS, timeZone: chicago) == "Feb 29, 2024")
        #expect(ScoutFormat.gameDate("2026-01-09T00:00:00Z", locale: enUS, timeZone: chicago) == "Jan 9, 2026")
        #expect(ScoutFormat.gameDate("2026-01-17", locale: Locale(identifier: "en_GB"), timeZone: chicago) == "17 Jan 2026")
    }

    @Test("gameDate never shifts the day, in any time zone")
    func gameDateNoShift() {
        for identifier in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "UTC", "Asia/Kolkata", "America/St_Johns", "America/New_York"] {
            let zone = TimeZone(identifier: identifier)!
            #expect(ScoutFormat.gameDate("2026-03-04", locale: enUS, timeZone: zone) == "Mar 4, 2026", "\(identifier)")
            // Daylight-saving start day in the US.
            #expect(ScoutFormat.gameDate("2026-03-08", locale: enUS, timeZone: zone) == "Mar 8, 2026", "\(identifier)")
        }
    }

    @Test("gameDate edge cases: empty, nil, not a date, rollover like the web")
    func gameDateEdges() {
        #expect(ScoutFormat.gameDate(nil, locale: enUS, timeZone: chicago) == "")
        #expect(ScoutFormat.gameDate("", locale: enUS, timeZone: chicago) == "")
        #expect(ScoutFormat.gameDate("garbage", locale: enUS, timeZone: chicago) == "garbage")
        #expect(ScoutFormat.gameDate("2026-00-10", locale: enUS, timeZone: chicago) == "2026-00-10")
        #expect(ScoutFormat.gameDate("2026-13-01", locale: enUS, timeZone: chicago) == "Jan 1, 2027")
    }

    @Test("gameDate from parts (the models' GameDate)")
    func gameDateFromParts() {
        #expect(ScoutFormat.gameDate(year: 2026, month: 1, day: 17, locale: enUS, timeZone: chicago) == "Jan 17, 2026")
        #expect(ScoutFormat.gameDate(year: 2026, month: 3, day: 4, locale: enUS, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!) == "Mar 4, 2026")
    }

    @Test("gameDateComponents and calendarDate")
    func gameDateParts() {
        let parts = ScoutFormat.gameDateComponents("2026-01-17")
        #expect(parts?.year == 2026)
        #expect(parts?.month == 1)
        #expect(parts?.day == 17)
        #expect(ScoutFormat.gameDateComponents("2026-01") == nil)
        #expect(ScoutFormat.gameDateComponents(nil) == nil)
        let date = ScoutFormat.calendarDate("2026-01-17", timeZone: chicago)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chicago
        #expect(date.map { calendar.component(.day, from: $0) } == 17)
        #expect(date.map { calendar.component(.hour, from: $0) } == 12)
    }

    // MARK: Date and time

    @Test("dateTime: toLocaleString style in the device time zone")
    func dateTime() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-11T16:00:00Z"))
        #expect(plain(ScoutFormat.dateTime(date, locale: enUS, timeZone: chicago)) == "11/11/2026, 10:00:00 AM")
        #expect(ScoutFormat.dateTime(nil, locale: enUS, timeZone: chicago) == "")
    }
}
