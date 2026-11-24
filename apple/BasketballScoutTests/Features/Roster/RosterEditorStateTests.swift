import Foundation
import Testing
@testable import BasketballScout

/// One team's editor (05 §7.2; roster.js `RosterEditor.load`): what it shows, unsaved changes, newer server
/// copies (09 R37), which rows a track can be assigned to.
struct RosterEditorStateTests {
    private func rosters() throws -> GameRosters {
        try Fixture.decode(GameRosters.self, "rosters_get_final.json")
    }

    @Test func loadingShowsThePlayersInOrderWithNoUnsavedChanges() throws {
        var editor = RosterEditorState(side: .scouted)
        try editor.load(rosters().scouted)
        #expect(editor.hasLoaded)
        #expect(!editor.isDirty)
        #expect(editor.teamName == "Test Team A")
        #expect(editor.rows.map(\.jersey) == ["0", "5", "11", "14", "33"])
        #expect(editor.rows.map(\.serverID) == ["p_fixture01", "p_fixture02", "p_fixture03", "p_fixture04", "p_fixture05"])
        #expect(editor.rosterPlayers.count == 5)
        #expect(editor.savedPlayer("p_fixture03")?.name == "Test Player 3")
        #expect(editor.rowNumber(editor.rows[2].id) == 3)
    }

    @Test func aRosterWithoutATeamNameShowsTheGamesName() {
        var editor = RosterEditorState(side: .other)
        editor.load(Roster(gameID: RosterTestHarness.gameID, side: .other), fallbackTeamName: "Test Team B")
        #expect(editor.teamName == "Test Team B")
        #expect(!editor.isDirty)
        editor.load(Roster(gameID: RosterTestHarness.gameID, side: .other, teamName: "Test Team B2"), fallbackTeamName: "Test Team B")
        #expect(editor.teamName == "Test Team B2")
    }

    @Test func editsThatAreUndoneAreNotUnsaved() throws {
        var editor = RosterEditorState(side: .scouted)
        try editor.load(rosters().scouted)
        editor.rows[1].firstName = "Changed"
        #expect(editor.isDirty)
        editor.rows[1].firstName = "Test"
        #expect(!editor.isDirty)
        editor.teamName = "Other name"
        #expect(editor.isDirty)
        editor.teamName = "Test Team A"
        editor.rows[0].revision += 1
        #expect(!editor.isDirty)
        editor.rows.append(RosterRowDraft())
        #expect(editor.isDirty)
    }

    @Test func aRowKeepsItsIdentityWhenItsPlayerComesBack() throws {
        var editor = RosterEditorState(side: .scouted)
        let roster = try rosters().scouted
        editor.load(roster)
        let identities = editor.rows.map(\.id)
        editor.rows.append(RosterRowDraft(jersey: "7"))
        editor.load(roster)
        #expect(editor.rows.map(\.id) == identities)
    }

    @Test func aNewerServerCopyIsNotedWhileEditing() throws {
        var editor = RosterEditorState(side: .scouted)
        var roster = try rosters().scouted
        editor.load(roster)
        editor.rows[0].lastName = "Player 99"
        editor.noteServerCopy(roster)
        #expect(editor.newerServerCopy == nil)

        roster.players.removeLast()
        roster.updatedAt = roster.updatedAt?.addingTimeInterval(60)
        editor.noteServerCopy(roster)
        #expect(editor.newerServerCopy == roster)
        #expect(editor.savedPlayer("p_fixture05") == nil)
        #expect(editor.rows.count == 5)
        #expect(editor.rows[0].lastName == "Player 99")
        editor.load(roster)
        #expect(editor.newerServerCopy == nil)
        #expect(editor.rows.count == 4)
    }

    @Test func onlyRowsWithAServerIDCanBeAssigned() throws {
        var editors = try RosterTestState.editors()
        editors.scouted.rows.append(RosterRowDraft(jersey: "7", firstName: "Test", lastName: "Player 11"))
        #expect(editors.scouted.rosterPlayers.count == 5)
        #expect(editors.rosterPlayer("p_fixture03", side: .scouted)?.label == "#11 Test Player 3")
        #expect(editors.rosterPlayer("p_fixture03", side: .other) == nil)
    }

    @Test func teamTitlesUseTheNameFieldOrTheSidesTitle() throws {
        var editors = try RosterTestState.editors()
        #expect(editors.teamTitle(.scouted) == "Test Team A")
        editors.other.teamName = "   "
        #expect(editors.teamTitle(.other) == "Their opponent in this film")
        #expect(editors.chipTitle(.other) == "Opponent")
        #expect(editors.chipTitle(.unknown("home")) == "home")
    }

    @Test func playerLabelsAreTheWebs() {
        #expect(RosterRowDraft(jersey: "5", firstName: "Test", lastName: "Player 1").label == "#5 Test Player 1")
        #expect(RosterRowDraft(jersey: "14").label == "#14")
        #expect(RosterRowDraft(jersey: "3", lastName: " Player 3 ").label == "#3 Player 3")
        #expect(RosterRowDraft(jersey: "3", position: "G", grade: "Sr", height: "6-2").details == "G · Sr · 6-2")
    }

    @Test func pendingChoicesKeepTheOrderTheyWereMadeIn() {
        var pending = RosterPendingChoices()
        pending.set(.notAPlayer, for: 8)
        pending.set(.automatic, for: 3)
        pending.set(.unknownKeepTeam, for: 8)
        #expect(pending.entries.map(\.trackID) == [8, 3])
        #expect(pending[8] == .unknownKeepTeam)
        pending.remove(8)
        pending.set(.notAPlayer, for: 8)
        #expect(pending.entries.map(\.trackID) == [3, 8])
        pending.removeAll()
        #expect(pending.isEmpty)
    }
}
