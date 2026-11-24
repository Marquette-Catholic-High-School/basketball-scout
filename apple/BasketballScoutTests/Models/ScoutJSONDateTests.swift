import Foundation
import Testing
@testable import BasketballScout

/// Dates per 09 R21/B11/C7: UTC `Z`, six fractional digits or none; parsed without OS-specific formatters,
/// so the results are the same on the minimum deployment OS (iOS 18 / macOS 15) as here.
nonisolated struct ScoutJSONDateTests {
    private struct Stamped: Codable, Equatable {
        var at: Date
        var maybe: Date?
    }

    @Test func parsesWithAndWithoutFraction() throws {
        let withFraction = try #require(ScoutTimestamp.date(from: "2026-11-11T19:53:10.180892Z"))
        let withoutFraction = try #require(ScoutTimestamp.date(from: "2026-11-11T10:00:00Z"))
        #expect(withoutFraction.timeIntervalSince1970 == 1_794_391_200)
        #expect(abs(withFraction.timeIntervalSince1970 - 1_794_426_790.180892) < 1e-6)
        // Microseconds that are not zero are written as 6 digits (C7).
        let tiny = try #require(ScoutTimestamp.date(from: "2026-11-11T10:00:00.000500Z"))
        #expect(abs(tiny.timeIntervalSince(withoutFraction) - 0.0005) < 1e-7)
    }

    @Test(arguments: [
        ("2026-11-11T10:00:00+00:00", 1_794_391_200.0),
        ("2026-11-11T05:00:00-05:00", 1_794_391_200.0),
        ("2026-11-11T11:30:00+0130", 1_794_391_200.0),
        ("2026-11-11T12:00:00+02", 1_794_391_200.0),
        ("2026-11-11t10:00:00z", 1_794_391_200.0),
        ("2026-11-11 10:00:00Z", 1_794_391_200.0),
        ("2026-11-11T10:00:00", 1_794_391_200.0),
        ("2026-11-11T10:00:00,5Z", 1_794_391_200.5),
        ("2026-11-11T10:00:00.123456789Z", 1_794_391_200.123456789),
        ("1970-01-01T00:00:00Z", 0.0),
        ("2024-02-29T23:59:59Z", 1_709_251_199.0),
        ("1969-12-31T23:59:59.5Z", -0.5),
    ])
    func parsesLenientForms(_ text: String, _ expected: Double) throws {
        let date = try #require(ScoutTimestamp.date(from: text))
        #expect(abs(date.timeIntervalSince1970 - expected) < 1e-6)
    }

    @Test(arguments: [
        "", "2026-11-11", "2026-11-11T10:00Z", "2026-13-01T00:00:00Z", "2026-02-29T00:00:00Z", "2026-11-31T00:00:00Z",
        "2026-11-11T24:00:00Z", "2026-11-11T10:60:00Z", "2026-11-11T10:00:60Z", "2026-11-11T10:00:00.Z",
        "2026-11-11T10:00:00Zjunk", "2026-11-11T10:00:00+25:00", "11/11/2026 10:00:00", "２０２６-11-11T10:00:00Z",
    ])
    func rejectsNonTimestamps(_ text: String) {
        #expect(ScoutTimestamp.date(from: text) == nil)
    }

    @Test func formatsLikeTheServer() throws {
        #expect(ScoutTimestamp.string(from: Date(timeIntervalSince1970: 1_794_391_200)) == "2026-11-11T10:00:00Z")
        #expect(ScoutTimestamp.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
        #expect(ScoutTimestamp.string(from: Date(timeIntervalSince1970: -0.5)) == "1969-12-31T23:59:59.500000Z")
        #expect(ScoutTimestamp.string(from: Date(timeIntervalSince1970: 1_709_251_199)) == "2024-02-29T23:59:59Z")
    }

    @Test(arguments: [
        "2026-11-11T19:53:10.180892Z", "2026-11-11T10:00:00Z", "2026-11-11T10:00:00.000500Z", "2026-11-11T20:05:15.168502Z",
        "2026-01-01T00:00:00.000001Z", "2099-12-31T23:59:59.999999Z",
    ])
    func serverTimestampsRoundTripExactly(_ text: String) throws {
        let date = try #require(ScoutTimestamp.date(from: text))
        #expect(ScoutTimestamp.string(from: date) == text)
    }

    @Test func everyTimestampInTheFixturesParses() throws {
        // 09: all 259 fixture timestamps have the `…:SS.ffffffZ` form.
        let pattern = /"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)"/
        var count = 0
        for name in Fixture.names(withExtension: "json") where name != "_manifest.json" {
            let text = try Fixture.text(name)
            for match in text.matches(of: pattern) {
                count += 1
                let value = String(match.output.1)
                let date = try #require(ScoutTimestamp.date(from: value), "\(name): \(value)")
                #expect(ScoutTimestamp.string(from: date) == value)
            }
        }
        #expect(count > 250)
    }

    @Test func decoderAndEncoderUseTheStrategy() throws {
        let json = Data(#"{"at":"2026-11-11T19:53:10.180892Z","maybe":"2026-11-11T10:00:00Z"}"#.utf8)
        let decoded = try ScoutJSON.decode(Stamped.self, from: json)
        #expect(decoded.maybe?.timeIntervalSince1970 == 1_794_391_200)
        let encoded = try #require(String(data: ScoutJSON.encode(decoded), encoding: .utf8))
        #expect(encoded == #"{"at":"2026-11-11T19:53:10.180892Z","maybe":"2026-11-11T10:00:00Z"}"#)

        #expect(throws: DecodingError.self) {
            try ScoutJSON.decode(Stamped.self, from: Data(#"{"at":"yesterday"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            // A date string is not a number: the default `.deferredToDate` strategy is not used.
            try ScoutJSON.decode(Stamped.self, from: Data(#"{"at":1794391200}"#.utf8))
        }
    }

    @Test func leaseExpiresAtIsEpochSecondsNotADate() throws {
        let job = try Fixture.decode(Job.self, "job_get.json")
        let lease = try #require(job.leaseExpiresAt)
        #expect(lease > 1_700_000_000)
        #expect(job.leaseExpiresDate == Date(timeIntervalSince1970: lease))
    }

    @Test func encoderOutputIsSortedAndDoesNotEscapeSlashes() throws {
        let body = try ScoutJSON.encode(VideoURLRequest(url: "https://example.com/films/a.mp4", filename: nil))
        #expect(String(decoding: body, as: UTF8.self) == #"{"filename":null,"url":"https://example.com/films/a.mp4"}"#)
    }
}

/// `game_date` is a calendar date string, never a datetime (09 R21).
nonisolated struct GameDateTests {
    @Test func parsesAndWritesYYYYMMDD() throws {
        let date = try #require(GameDate("2026-01-09"))
        #expect(date.year == 2026 && date.month == 1 && date.day == 9)
        #expect(date.description == "2026-01-09")
        #expect(GameDate("2026-01-09T00:00:00Z") == date)
        #expect(GameDate("2026-1-9") == nil)
        #expect(GameDate("") == nil)
        #expect(GameDate("01/09/2026") == nil)
        #expect(GameDate("2026-02-30") == nil)
        #expect(GameDate("2024-02-29") != nil)
        #expect(GameDate(year: 0, month: 1, day: 1) == nil)
        #expect(GameDate(year: 2026, month: 2, day: 2)! < GameDate(year: 2026, month: 11, day: 1)!)
    }

    @Test func codableAsAPlainString() throws {
        let game = try Fixture.decode(Game.self, "game_create.json")
        #expect(game.gameDate?.description == "2026-11-07")
        let body = try ScoutJSON.encode(["game_date": GameDate("2026-11-07")])
        #expect(String(decoding: body, as: UTF8.self) == #"{"game_date":"2026-11-07"}"#)
        #expect(throws: DecodingError.self) {
            try ScoutJSON.decode([String: GameDate].self, from: Data(#"{"d":"11/07/2026"}"#.utf8))
        }
    }

    @Test(arguments: ["UTC", "America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Pago_Pago"])
    func noDayShiftInAnyTimeZone(_ zone: String) throws {
        let date = try #require(GameDate("2026-01-09"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let local = try #require(date.date(in: calendar))
        #expect(GameDate(local, calendar: calendar) == date)
        #expect(date.formatted(locale: Locale(identifier: "en_US")) == "Jan 9, 2026")
    }

    @Test func formatsLikeTheWeb() throws {
        let date = try #require(GameDate("2026-01-17"))
        #expect(date.formatted(.abbreviated, locale: Locale(identifier: "en_US")) == "Jan 17, 2026")
        #expect(date.formatted(.long, locale: Locale(identifier: "en_US")) == "January 17, 2026")
    }
}
