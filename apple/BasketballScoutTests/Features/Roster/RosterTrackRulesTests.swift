import Foundation
import Testing
@testable import BasketballScout

/// The jersey-assignment rules (05 §7.5–§7.10; roster.js:284-464): what an override means, when a choice is
/// pending, what it sends, the players removed from the roster, the filter, the order, the choice list.
struct RosterTrackRulesTests {
    @Test func savedOverridesMeanTheWebsChoices() throws {
        let editors = try RosterTestState.editors()
        let tracks = RosterTracksState()
        #expect(tracks.choice(for: nil, editors: editors) == .automatic)
        #expect(tracks.choice(for: TrackOverride(trackID: 1, ignore: true), editors: editors) == .notAPlayer)
        #expect(tracks.choice(for: TrackOverride(trackID: 1, side: .other), editors: editors) == .unknownPlayer(.other))
        #expect(tracks.choice(for: TrackOverride(trackID: 1), editors: editors) == .unknownKeepTeam)
        #expect(tracks.choice(for: TrackOverride(trackID: 1, playerID: "p_fixture07", side: .other), editors: editors)
            == .player(.other, "p_fixture07"))
        // The saved rosters decide the team (scouted first), not the override's side.
        #expect(tracks.choice(for: TrackOverride(trackID: 1, playerID: "p_fixture02", side: .other), editors: editors)
            == .player(.scouted, "p_fixture02"))
        #expect(tracks.choice(for: TrackOverride(trackID: 1, playerID: "p_gone", side: .scouted), editors: editors) == .automatic)
    }

    @Test func thePickerShowsTheUnsavedChoiceElseTheSavedOne() throws {
        let editors = try RosterTestState.editors()
        var tracks = try RosterTestState.tracks()
        #expect(tracks.currentChoice(7, editors: editors) == .player(.scouted, "p_fixture05"))
        #expect(tracks.currentChoice(13, editors: editors) == .notAPlayer)
        #expect(tracks.currentChoice(3, editors: editors) == .automatic)
        tracks.choose(.unknownPlayer(.scouted), for: 3, editors: editors)
        #expect(tracks.currentChoice(3, editors: editors) == .unknownPlayer(.scouted))
        #expect(tracks.pending.count == 1)
    }

    @Test func choosingTheSavedChoiceAgainIsNotAChange() throws {
        let editors = try RosterTestState.editors()
        var tracks = try RosterTestState.tracks()
        tracks.choose(.automatic, for: 7, editors: editors)
        #expect(tracks.pending[7] == .automatic)
        tracks.choose(.player(.scouted, "p_fixture05"), for: 7, editors: editors)
        #expect(tracks.pending.isEmpty)
        tracks.choose(.automatic, for: 3, editors: editors)
        #expect(tracks.pending.isEmpty)
    }

    @Test func keepTeamOnATrackSavedAsItsTeamsUnknownPlayerChangesNothing() throws {
        let editors = try RosterTestState.editors()
        var tracks = try RosterTestState.tracks("tracks_with_overrides.json")
        // Track 12 (other) is saved as the opponent's unknown player.
        #expect(tracks.currentChoice(12, editors: editors) == .unknownPlayer(.other))
        tracks.choose(.unknownKeepTeam, for: 12, editors: editors)
        #expect(tracks.pending.isEmpty)
        tracks.choose(.unknownPlayer(.scouted), for: 12, editors: editors)
        #expect(tracks.pending[12] == .unknownPlayer(.scouted))
    }

    @Test func bodiesFollowTheWeb() throws {
        let tracks = try RosterTestState.tracks()
        #expect(tracks.body(for: 3, choice: .automatic) == nil)
        #expect(tracks.body(for: 3, choice: .notAPlayer) == TrackOverrideBody(trackID: 3, playerID: nil, side: .scouted, ignore: true))
        #expect(tracks.body(for: 6, choice: .unknownKeepTeam) == TrackOverrideBody(trackID: 6, playerID: nil, side: .other, ignore: false))
        // A referee shows no team: "keep team" and "Not a player" send none.
        #expect(tracks.body(for: 14, choice: .unknownKeepTeam) == TrackOverrideBody(trackID: 14, playerID: nil, side: nil, ignore: false))
        #expect(tracks.body(for: 14, choice: .notAPlayer) == TrackOverrideBody(trackID: 14, playerID: nil, side: nil, ignore: true))
        #expect(tracks.body(for: 3, choice: .unknownPlayer(.other)) == TrackOverrideBody(trackID: 3, playerID: nil, side: .other, ignore: false))
        #expect(tracks.body(for: 3, choice: .player(.scouted, "p_fixture04"))
            == TrackOverrideBody(trackID: 3, playerID: "p_fixture04", side: .scouted, ignore: false))
    }

    @Test func removingAPlayerDropsTheUnsavedChoicesThatNameThem() throws {
        var editors = try RosterTestState.editors()
        var tracks = try RosterTestState.tracks()
        tracks.choose(.player(.scouted, "p_fixture03"), for: 3, editors: editors)
        tracks.choose(.player(.scouted, "p_fixture03"), for: 2, editors: editors)
        tracks.choose(.notAPlayer, for: 14, editors: editors)
        editors.scouted.rows.removeAll { $0.serverID == "p_fixture03" }
        let dropped = tracks.dropChoicesOfRemovedPlayers(editors: editors)
        #expect(dropped)
        #expect(tracks.pending.entries.map(\.trackID) == [14])
        #expect(tracks.removedChoicesNotice == RosterNotice(
            tone: .warning, title: "Track choices dropped",
            message: "Your unsaved choices for tracks T2 and T3 were dropped: their players were removed from the roster."))
        let droppedAgain = tracks.dropChoicesOfRemovedPlayers(editors: editors)
        #expect(!droppedAgain)
    }

    @Test func aSavedAssignmentToARemovedPlayerStaysListedUntilTheRosterIsSaved() throws {
        var editors = try RosterTestState.editors()
        let tracks = try RosterTestState.tracks()
        editors.scouted.rows.removeAll { $0.serverID == "p_fixture05" }
        #expect(tracks.currentChoice(7, editors: editors) == .player(.scouted, "p_fixture05"))
        let menu = tracks.choiceMenu(for: 7, editors: editors)
        #expect(menu.title(for: .player(.scouted, "p_fixture05")) == "#33 Test Player 5 (removed, not saved yet)")
        // Other tracks do not offer the removed player.
        #expect(tracks.choiceMenu(for: 3, editors: editors).title(for: .player(.scouted, "p_fixture05")) == nil)
    }

    @Test func theChoiceListHasEveryTeamsUnknownPlayerAndSavedPlayers() throws {
        var editors = try RosterTestState.editors()
        editors.scouted.rows.append(RosterRowDraft(jersey: "7", firstName: "Test", lastName: "Player 11"))
        editors.other.teamName = ""
        let menu = try RosterTestState.tracks().choiceMenu(for: 3, editors: editors)
        #expect(menu.general.map(\.title) == [
            "Automatic (best jersey match)", "Unknown player (keep team)", "Not a player (referee, coach, fan…)",
        ])
        #expect(menu.groups.map(\.title) == ["Test Team A", "Their opponent in this film"])
        #expect(menu.groups[0].options.map(\.title) == [
            "Unknown player (Test Team A)", "#0 Test Player 1", "#5 Test Player 2", "#11 Test Player 3",
            "#14 Test Player 4", "#33 Test Player 5",
        ])
        #expect(menu.groups[1].options.first?.title == "Unknown player (Their opponent in this film)")
        #expect(menu.groups[1].options.count == 6)
    }

    @Test func theFilterShowsWhatTheWebShows() throws {
        let editors = try RosterTestState.editors()
        var tracks = try RosterTestState.tracks("tracks_unmatched.json")
        func shown(_ filter: RosterTrackFilter) -> [Int] {
            tracks.filter = filter
            return tracks.rows(editors: editors).map(\.trackID)
        }
        #expect(shown(.all).count == 15)
        #expect(shown(.scouted) == [3, 8, 7, 4, 11, 2])
        #expect(shown(.other) == [6, 1, 9, 5, 10, 12])
        #expect(shown(.attention).count == 12)
        #expect(shown(.ignored).isEmpty)
        tracks.choose(.notAPlayer, for: 15, editors: editors)
        tracks.choose(.unknownPlayer(.scouted), for: 3, editors: editors)
        #expect(shown(.ignored) == [15])
        #expect(!shown(.attention).contains(3))
        #expect(tracks.countText(shown: 1) == "1 of 15 tracks")
    }

    /// "Name these first" and the match-rate line (roster.js `matchProjection`; tests/test_name_first.py): the
    /// longest unnamed team tracks whatever the team, their share, and a forecast that follows the choices.
    @Test func nameTheseFirstListsTheLongestUnnamedTracksAndTheGoal() throws {
        let editors = try RosterTestState.editors()
        var tracks = try RosterTestState.tracks("tracks_unmatched.json")
        let projection = try #require(tracks.matchProjection(editors: editors))
        #expect(projection.total == 59990) // the referees do not count
        #expect(projection.text == "Jersey match rate: 0%. Naming the 8 longest unnamed tracks brings it to 75%.")
        #expect(projection.canReachGoal)
        tracks.filter = .first
        let rows = tracks.rows(editors: editors)
        #expect(rows.map(\.trackID) == [1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 2, 12])
        #expect(rows.first?.seenText == "6000 (10.0%)")
        tracks.choose(.player(.scouted, "p_fixture02"), for: 3, editors: editors)
        #expect(tracks.rows(editors: editors).map(\.trackID).contains(3)) // a row chosen stays in the list
        #expect(tracks.matchProjection(editors: editors)?.text
            == "Jersey match rate: 0%. With your unsaved choices: about 10%. Naming the 7 longest unnamed tracks brings it to 75%.")
        tracks.choose(.notAPlayer, for: 1, editors: editors)
        #expect(tracks.matchProjection(editors: editors)?.total == 53990)
        tracks.filter = .all
        #expect(tracks.rows(editors: editors).first?.seenText == "6000") // the other views keep the plain count
    }

    @Test func rowsComeInTheWebsOrder() throws {
        let rows = try RosterTestState.tracks().rows(editors: RosterTestState.editors())
        // Players first; scouted, other, no team; most frames first; ties keep the server's order.
        #expect(rows.map(\.trackID) == [3, 8, 7, 4, 11, 2, 6, 1, 9, 5, 10, 12, 13, 14, 15])
    }

    @Test func tracksOfAnotherRunAreNotTheSame() throws {
        let tracks = try RosterTestState.tracks()
        var fresh = try Fixture.decode(TrackState.self, "tracks.json").assignments
        #expect(tracks.hasSameTracks(as: Array(fresh.reversed())))
        // Overrides applied by a re-analysis change player and method, not the GPU run's keys.
        fresh[0].playerID = nil
        fresh[0].method = .manual
        #expect(tracks.hasSameTracks(as: fresh))
        fresh[0].frames += 1
        #expect(!tracks.hasSameTracks(as: fresh))
    }

    @Test func droppingTheTracksSaysWhetherChoicesWent() throws {
        let editors = try RosterTestState.editors()
        var tracks = try RosterTestState.tracks()
        let droppedNothing = tracks.drop()
        #expect(!droppedNothing)
        tracks = try RosterTestState.tracks()
        tracks.choose(.notAPlayer, for: 14, editors: editors)
        let droppedChoices = tracks.drop()
        #expect(droppedChoices)
        #expect(!tracks.isShown)
        #expect(tracks.assignments.isEmpty && tracks.overrides.isEmpty && tracks.pending.isEmpty)
    }

    @Test func aFullAnalysisIsAnActiveAnalyze() throws {
        #expect(RosterPageModel.isFullAnalysis(try Fixture.decode(Job.self, "job_running_before_cancel.json")))
        #expect(RosterPageModel.isFullAnalysis(try Fixture.decode(Job.self, "job_create_analyze_full.json")))
        #expect(!RosterPageModel.isFullAnalysis(try Fixture.decode(Job.self, "job_reanalyze_2_running_analyzing.json")))
        #expect(!RosterPageModel.isFullAnalysis(try Fixture.decode(Job.self, "job_analyze_4_succeeded_done.json")))
    }

    @Test func anAnalyzeRenumbersTheTracksOnceItsResultsAreInstalled() throws {
        #expect(RosterPageModel.tracksRenumbered(try Fixture.decode(Job.self, "job_analyze_4_succeeded_done.json")))
        // A late cancel ends succeeded.
        #expect(RosterPageModel.tracksRenumbered(try Fixture.decode(Job.self, "job_late_cancel_2_succeeded_done.json")))
        #expect(!RosterPageModel.tracksRenumbered(try Fixture.decode(Job.self, "job_cancelled_2_cancelled_done.json")))
        #expect(!RosterPageModel.tracksRenumbered(try Fixture.decode(Job.self, "job_failed_1_failed_preparing.json")))
        #expect(!RosterPageModel.tracksRenumbered(try Fixture.decode(Job.self, "job_reanalyze_3_succeeded_done.json")))
        var failedLate = try Fixture.decode(Job.self, "job_failed_1_failed_preparing.json")
        failedLate.stage = .analyzing
        #expect(RosterPageModel.tracksRenumbered(failedLate))
    }
}
