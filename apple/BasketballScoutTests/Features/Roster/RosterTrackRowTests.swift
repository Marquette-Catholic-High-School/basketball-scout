import Foundation
import Testing
@testable import BasketballScout

/// The tracks table's cells (roster.html:76-86; roster.js `votesText`, `matchedText`, `scoreText`, "How").
struct RosterTrackRowTests {
    private func row(_ trackID: Int, fixture: String = "tracks.json") throws -> RosterTrackRow {
        let tracks = try RosterTestState.tracks(fixture)
        let assignment = try #require(tracks.assignments.first { $0.trackID == trackID })
        return tracks.row(for: assignment, editors: try RosterTestState.editors())
    }

    @Test func aMatchedTrackShowsItsPlayerAndReadings() throws {
        let track = try row(3)
        #expect(track.trackText == "T3")
        #expect(track.roleBadge == nil)
        #expect(track.teamTitle == "Test Team A")
        #expect(track.frames == 6000)
        #expect(track.bestReadText == "#14")
        #expect(track.readingsText == "#14 93%, #4 3%, #74 2%")
        #expect(track.matchedText == "#14 Test Player 4")
        #expect(track.matchText == "97%")
        #expect(track.howText == "Exact read")
        #expect(!track.isPending)
    }

    @Test func aTrackSetByHandToAPlayerShowsAFullMatch() throws {
        let track = try row(7)
        #expect(track.matchedText == "#33 Test Player 5")
        #expect(track.matchText == "100%")
        #expect(track.howText == "Set by you")
        #expect(track.choice == .player(.scouted, "p_fixture05"))
    }

    @Test func aRefereeHasNoTeamReadsOrScore() throws {
        let ignored = try row(13)
        #expect(ignored.roleBadge == "referee")
        #expect(ignored.teamTitle == nil)
        #expect(ignored.bestReadText == "–")
        #expect(ignored.readingsText == "–")
        #expect(ignored.matchedText == "–")
        #expect(ignored.matchText == "–")
        #expect(ignored.isIgnored)
        #expect(ignored.choice == .notAPlayer)
        let unread = try row(14)
        #expect(unread.howText == "No readable jersey")
        #expect(unread.matchText == "–")
    }

    @Test func aJerseyNotOnTheRosterSaysSo() throws {
        let track = try row(3, fixture: "tracks_unmatched.json")
        #expect(track.matchedText == "#14 (not on roster)")
        #expect(track.howText == "Not on roster")
        #expect(track.matchText == "93%")
    }

    @Test func anUnclearMatchIsExplained() {
        let assignment = TrackAssignment(trackID: 9, teamID: 1, side: .other, bestRead: "20", votes: ["20": 3, "2": 1],
                                         matchScore: 0.75, method: .unrostered, frames: 120)
        let track = RosterTrackRow(assignment: assignment, choice: .automatic, isPending: true, teamTitle: "Opponent", matchedText: "–")
        #expect(track.isUnclearMatch)
        #expect(track.howText == "Unclear match")
        #expect(track.readingsText == "#20 75%, #2 25%")
        #expect(track.accessibilitySummary == "Track 9, Opponent, Best read #20, Matched player –, Unsaved")
    }

    @Test func aScoreTheServerSentAsNullShowsADash() {
        let assignment = TrackAssignment(trackID: 1, side: .scouted, votes: ["5": .nan], matchScore: .nan, method: .fuzzy, frames: 10)
        let track = RosterTrackRow(assignment: assignment, choice: .automatic, isPending: false, teamTitle: nil, matchedText: "–")
        #expect(track.matchText == "–")
        #expect(track.readingsText == "–")
        #expect(track.matchSortKey == -1)
    }

    @Test func bestReadsSortAsJerseys() {
        func key(_ read: String?) -> Int {
            RosterTrackRow(
                assignment: TrackAssignment(trackID: 1, bestRead: read), choice: .automatic, isPending: false,
                teamTitle: nil, matchedText: "").bestReadSortKey
        }
        #expect(key("0") < key("00"))
        #expect(key("00") < key("1"))
        #expect(key("9") < key("10"))
        #expect(key(nil) == Int.max)
    }
}
