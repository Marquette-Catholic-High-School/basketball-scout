import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BasketballScout

/// The import's checks before sending and its summary (05 §7.3; roster.js:219-257).
struct RosterImportTests {
    @Test(arguments: ["roster.csv", "Roster.TSV", "team.txt", "Test Roster.XLSX"])
    func rosterFilesAreAccepted(_ name: String) {
        #expect(RosterImportCheck.unsupportedProblem(filename: name) == nil)
    }

    @Test(arguments: ["roster.pdf", "roster.numbers", "roster.xls", "roster", "roster.csv.zip"])
    func otherFilesAreRefusedWithTheWebsWords(_ name: String) throws {
        let problem = try #require(RosterImportCheck.unsupportedProblem(filename: name))
        #expect(problem.title == "Unsupported roster file")
        #expect(problem.message == "\"\(name)\" is not a CSV or Excel (.xlsx) file.")
        #expect(problem.hint == "Save the roster as CSV or .xlsx and try again.")
    }

    @Test func filesOverTwoMegabytesAreRefused() throws {
        #expect(RosterImportCheck.tooLargeProblem(filename: "roster.csv", bytes: 2_097_152) == nil)
        let problem = try #require(RosterImportCheck.tooLargeProblem(filename: "roster.csv", bytes: 2_097_153))
        #expect(problem.title == "Roster file too large")
        #expect(problem.message == "\"roster.csv\" is 2.0 MB; roster files must be under 2 MB.")
        #expect(problem.hint == "Remove extra sheets or columns and try again.")
        #expect(RosterImportCheck.tooLargeProblem(filename: "big.xlsx", bytes: 5_452_595)?.message
            == "\"big.xlsx\" is 5.2 MB; roster files must be under 2 MB.")
    }

    @Test func theSummaryIsTheWebsNotice() throws {
        let result = try Fixture.decode(RosterImportResult.self, "roster_import.json")
        let summary = RosterImportCheck.summary(of: result, filename: "Test Roster.csv", changes: RosterImportChanges(added: 1, updated: 3))
        #expect(summary.title == "Imported 4 players from Test Roster.csv")
        #expect(summary.changes == "1 added, 3 updated.")
        #expect(summary.hasDetails)
        #expect(summary.columns == "Columns used: Jersey ← \"Jersey\", First name ← \"First Name\", Last name ← \"Last Name\", "
            + "Position ← \"Position\", Grade ← \"Grade\", Height ← \"Height\", Notes ← \"Notes\"")
        #expect(summary.skippedTitle == "1 row was skipped:")
        #expect(summary.skipped == ["Row 5: invalid jersey number 'abc'"])
        #expect(summary.warnings == [
            "Row 5: 'abc' is not a jersey number (0-99), so Test Player 13 was skipped.", "Row 6: #14 has no name.",
        ])
    }

    @Test func countsAreWorded() {
        #expect(RosterText.imported(1, from: "a.csv") == "Imported 1 player from a.csv")
        #expect(RosterText.imported(0, from: "a.csv") == "Imported 0 players from a.csv")
        #expect(RosterText.skippedRows(2) == "2 rows were skipped:")
        #expect(RosterText.columnsUsed([]) == nil)
        let empty = RosterImportCheck.summary(
            of: RosterImportResult(roster: Roster(gameID: RosterTestHarness.gameID, side: .other), imported: 2), filename: "a.csv")
        #expect(empty.skippedTitle == nil && empty.columns == nil && empty.warnings.isEmpty)
    }

    @Test func whatAnImportChangedIsCountedFromTheRosterBeforeAndAfter() throws {
        let before = try Fixture.decode(GameRosters.self, "rosters_get_final.json").other.players
        let byID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        // Merge: one player's details updated, one new player appended.
        var merged = before
        merged[1].notes = "Changed in the file"
        merged.append(RosterPlayer(id: "p_000000000099", jersey: "99", firstName: "Test", lastName: "Player 99"))
        #expect(RosterImportChanges(before: byID, after: merged) == RosterImportChanges(added: 1, updated: 1, removed: 0))
        // Replace: the file had two of the players, unchanged.
        let replaced = Array(before.prefix(2))
        let changes = RosterImportChanges(before: byID, after: replaced)
        #expect(changes == RosterImportChanges(added: 0, updated: 0, removed: 3))
        #expect(changes.text == "3 removed.")
        #expect(RosterImportChanges(before: byID, after: before).text == "The roster did not change.")
        #expect(RosterImportChanges(added: 2, updated: 1, removed: 1).text == "2 added, 1 updated, 1 removed.")
    }

    @Test func theFilePickerOffersRosterFiles() {
        let identifiers = RosterImportCheck.pickerTypes.map(\.identifier)
        #expect(identifiers.contains("public.comma-separated-values-text"))
        #expect(identifiers.contains("public.tab-separated-values-text"))
        #expect(identifiers.contains("public.plain-text"))
        #expect(identifiers.contains("org.openxmlformats.spreadsheetml.sheet"))
    }

    @Test func aDroppedCopyIsDeletedButAPickedFileIsNot() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RosterImportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picked = folder.appending(path: "picked.csv")
        try Data("Jersey,Name\n5,Test Player 1\n".utf8).write(to: picked)
        RosterImportFile(url: picked).discard()
        #expect(FileManager.default.fileExists(atPath: picked.path(percentEncoded: false)))

        let copyFolder = folder.appending(path: "copy", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copyFolder, withIntermediateDirectories: true)
        let copy = copyFolder.appending(path: "dropped.csv")
        try Data("Jersey,Name\n".utf8).write(to: copy)
        RosterImportFile(url: copy, isTemporaryCopy: true).discard()
        #expect(!FileManager.default.fileExists(atPath: copyFolder.path(percentEncoded: false)))
    }

    @Test func leftoverCopiesAreSweptAway() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "RosterImportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let leftover = root.appending(path: "\(RosterImportFile.copiesFolderName)/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("Jersey,Name\n".utf8).write(to: leftover.appending(path: "roster.csv"))
        RosterImportFile.removeLeftoverCopies(under: root)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: RosterImportFile.copiesFolderName).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }
}
