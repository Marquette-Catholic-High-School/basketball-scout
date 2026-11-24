import Foundation
import Testing
@testable import BasketballScout

/// The page's sentences that depend on what happened (roster.js `sayRemovedChoices`, `finishedNotice`,
/// `numberedAgainNotice`, `updatePendingNote`).
struct RosterTextTests {
    @Test func droppedChoicesListTheirTracks() {
        #expect(RosterText.choicesDropped([]) == nil)
        #expect(RosterText.choicesDropped([8])
            == "Your unsaved choice for track T8 was dropped: its player was removed from the roster.")
        #expect(RosterText.choicesDropped([5, 3])
            == "Your unsaved choices for tracks T3 and T5 were dropped: their players were removed from the roster.")
        #expect(RosterText.choicesDropped([12, 3, 5])
            == "Your unsaved choices for tracks T3, T5 and T12 were dropped: their players were removed from the roster.")
    }

    @Test func unsavedChangesAreCounted() {
        #expect(RosterText.unsavedCount(0) == nil)
        #expect(RosterText.unsavedCount(1) == "1 unsaved change")
        #expect(RosterText.unsavedCount(3) == "3 unsaved changes")
    }

    @Test func numberedAgainPointsToTheNewTableOrTheGamePage() {
        let withTable = RosterText.numberedAgain(tableShown: true)
        #expect(withTable.title == "Film analysed again")
        #expect(withTable.hint == "Make them again in the new table.")
        #expect(withTable.action == nil)
        let withoutTable = RosterText.numberedAgain(tableShown: false)
        #expect(withoutTable.hint == "There are no tracks to assign now: see the game page.")
        #expect(withoutTable.action == .openGamePage)
    }

    @Test func nothingIsSaidWhenNothingChanged() {
        #expect(RosterText.analysisFinished(dropped: false, tableShownBefore: true, hadRows: true, tableShownNow: true, hasRowsNow: true) == nil)
        // A first analysis that left no table, with none shown before.
        #expect(RosterText.analysisFinished(dropped: false, tableShownBefore: false, hadRows: false, tableShownNow: false, hasRowsNow: false) == nil)
    }

    @Test func droppedChoicesWithANewTableAreSaid() {
        let notice = RosterText.analysisFinished(dropped: true, tableShownBefore: true, hadRows: true, tableShownNow: true, hasRowsNow: true)
        #expect(notice == RosterNotice(
            tone: .info, title: "Film analysis finished",
            message: "It numbered the players' tracks again, so your unsaved track choices were dropped. Make them again in the new table."))
    }

    @Test func noTableAfterTheAnalysisSendsToTheGamePage() {
        let quiet = RosterText.analysisFinished(dropped: false, tableShownBefore: true, hadRows: true, tableShownNow: false, hasRowsNow: false)
        #expect(quiet?.title == "Film analysis finished without results")
        #expect(quiet?.message == "There are no tracks to assign now.")
        #expect(quiet?.hint == "See the game page for what went wrong.")
        #expect(quiet?.action == .openGamePage)
        let dropped = RosterText.analysisFinished(dropped: true, tableShownBefore: true, hadRows: true, tableShownNow: false, hasRowsNow: false)
        #expect(dropped?.message == "A full analysis numbers the players' tracks again, so your unsaved track choices were dropped.")
    }

    @Test func aTableThatCouldNotBeReadAsksForAReload() {
        let after = RosterText.analysisFinished(dropped: false, tableShownBefore: true, hadRows: true, tableShownNow: true, hasRowsNow: false)
        #expect(after == RosterNotice(
            tone: .warning, title: "Film analysis finished", message: "It numbered the players' tracks again.",
            hint: "Reload the page to see the new table.", action: .reloadPage))
        let first = RosterText.analysisFinished(dropped: false, tableShownBefore: false, hadRows: false, tableShownNow: true, hasRowsNow: false)
        #expect(first?.message == nil)
        let dropped = RosterText.analysisFinished(dropped: true, tableShownBefore: true, hadRows: true, tableShownNow: true, hasRowsNow: false)
        #expect(dropped?.message == "It numbered the players' tracks again, so your unsaved track choices were dropped.")
    }

    @Test func theFilterIsTheWebs() {
        #expect(RosterTrackFilter.allCases.map(\.title) == [
            "All tracks", "Needs attention (no player)", "Scouted team", "Opponent", "Not a player",
        ])
        #expect(RosterSection.roster(.scouted).title == "Scouted team")
        #expect(RosterSection.roster(.other).title == "Opponent")
        #expect(RosterSection.tracks.title == "Jersey assignments")
    }
}
