import Foundation
import Testing
@testable import BasketballScout

/// The roster editor's checks before saving (05 §7.2 "Save", roster.js `collect()`; 09 D1 #3–#4) and the
/// fields' typing limits (the web's `maxlength`, 09 R41).
struct RosterValidationTests {
    private typealias Row = RosterTestState

    @Test func cellsAreTrimmedEmptyOptionalsAreNullAndNewRowsHaveNoID() throws {
        let rows = [
            Row.row(" #5 ", " Test ", " Player 1 ", serverID: "p_fixture01", position: "  "),
            Row.row("# 12", "Test", "Player 2", notes: " Fixture note "),
        ]
        guard case .players(let players) = RosterValidation.collect(rows) else {
            Issue.record("expected players")
            return
        }
        #expect(players.count == 2)
        #expect(players[0] == RosterPlayerInput(id: "p_fixture01", jersey: "5", firstName: "Test", lastName: "Player 1"))
        #expect(players[0].position == nil)
        #expect(players[1].id == nil)
        #expect(players[1].jersey == "12")
        #expect(players[1].notes == "Fixture note")
    }

    @Test func blankRowsAreSkippedButCounted() {
        let rows = [Row.row("5", "Test", "Player 1"), Row.row("  ", " "), Row.row("abc", "Test", "Player 3")]
        #expect(RosterValidation.collect(rows) == .problem(
            message: "Row 3: a jersey number is one or two digits (0-99), not \"abc\".", index: 2))
    }

    @Test func aRowWithANameNeedsAJersey() {
        let rows = [Row.row("", "Test", "Player 1")]
        #expect(RosterValidation.collect(rows) == .problem(message: "Row 1 needs a jersey number.", index: 0))
        #expect(RosterValidation.collect([Row.row("#", "Test")]) == .problem(message: "Row 1 needs a jersey number.", index: 0))
    }

    @Test(arguments: ["123", "5a", "٥", "５", "-1", "1.0"])
    func onlyOneOrTwoASCIIDigitsAreAJersey(_ typed: String) {
        #expect(RosterValidation.collect([Row.row(typed, "Test")]) == .problem(
            message: "Row 1: a jersey number is one or two digits (0-99), not \"\(typed)\".", index: 0))
    }

    @Test func theMessageQuotesTheJerseyAsTypedWithItsHash() {
        #expect(RosterValidation.collect([Row.row(" #123 ")]) == .problem(
            message: "Row 1: a jersey number is one or two digits (0-99), not \"#123\".", index: 0))
    }

    @Test func exactDuplicatesAreRefused() {
        let rows = [Row.row("5", "Test"), Row.row("7"), Row.row("#5", "Test", "Player 3")]
        #expect(RosterValidation.collect(rows) == .problem(message: "Jersey #5 is listed twice (rows 1 and 3).", index: 2))
    }

    @Test func zeroAndDoubleZeroAndFiveAndOhFiveAreDifferentJerseys() {
        let rows = [Row.row("0"), Row.row("00"), Row.row("5"), Row.row("05")]
        guard case .players(let players) = RosterValidation.collect(rows) else {
            Issue.record("expected players")
            return
        }
        #expect(players.map(\.jersey) == ["0", "00", "5", "05"])
    }

    @Test func fiveAndOhFiveGetAWarning() {
        let rows = [Row.row("5"), Row.row("7"), Row.row(""), Row.row("05", "Test")]
        #expect(RosterValidation.sameNumberWarnings(rows) == [
            "Jersey #5 / #05 is listed 2 times (rows 1, 4). Film matching reads them as the same number; remove the extra so film matching is not ambiguous.",
        ])
        #expect(RosterValidation.sameNumberWarnings([Row.row("0"), Row.row("00")]).isEmpty)
        #expect(RosterValidation.sameNumberWarnings([Row.row("5"), Row.row("5")]).isEmpty)
        #expect(RosterValidation.sameNumberWarnings([Row.row("5"), Row.row("abc"), Row.row("50")]).isEmpty)
    }

    @Test func theNumberKeyIsTheImporters() {
        #expect(RosterValidation.numberKey("05") == "5")
        #expect(RosterValidation.numberKey("5") == "5")
        #expect(RosterValidation.numberKey("0") == "0")
        #expect(RosterValidation.numberKey("00") == "00")
        #expect(RosterValidation.numberKey("50") == "50")
    }

    // MARK: - Typing limits

    @Test func theJerseyKeepsDigitsHashAndSpaces() {
        #expect(RosterField.jersey.accept("#1a", replacing: "#1") == "#1")
        #expect(RosterField.jersey.accept("٥", replacing: "") == "5")
        #expect(RosterField.jersey.accept("１２", replacing: "") == "12")
        #expect(RosterField.jersey.accept("# 5", replacing: "#") == "# 5")
        #expect(RosterField.jersey.accept("Ⅻ", replacing: "") == "")
    }

    @Test func fieldsStopAtTheirMaxLength() {
        #expect(RosterField.jersey.accept("1234", replacing: "123") == nil)
        #expect(RosterField.jersey.accept("12345", replacing: "") == "123")
        let long = String(repeating: "a", count: 121)
        #expect(RosterField.notes.accept(long, replacing: "")?.count == 120)
        #expect(RosterField.notes.accept(long, replacing: String(repeating: "a", count: 120)) == nil)
        // A longer value loaded from the server stays, and deleting from it works.
        let loaded = String(repeating: "b", count: 300)
        #expect(RosterField.notes.accept(loaded + "c", replacing: loaded) == nil)
        #expect(RosterField.notes.accept(String(loaded.dropLast()), replacing: loaded) == String(loaded.dropLast()))
        #expect(RosterField.limit(long, replacing: "", maxLength: RosterField.teamNameMaxLength)?.count == 120)
    }

    @Test func columnTitlesAndLabelsAreTheWebs() {
        #expect(RosterField.allCases.map(\.columnTitle) == ["#", "First name", "Last name", "FastScout name", "Pos", "Gr", "Ht", "Notes"])
        #expect(RosterField.allCases.map(\.label) == [
            "Jersey", "First name", "Last name", "FastScout name", "Position", "Grade", "Height", "Notes",
        ])
    }
}
