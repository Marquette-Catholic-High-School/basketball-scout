import Foundation
import Testing
@testable import BasketballScout

/// The "Which team is …?" banner's buttons (03 §7.6, 06 §5.3; game.js `teamChoiceLabels`, `confirmTeam`).
@MainActor
struct GameDetailTeamChoiceTests {
    private func team(_ side: TeamSide, id: Int? = nil, rgb: [Int]? = nil, name: String? = nil) -> TeamSummary {
        TeamSummary(
            side: side, name: side == .scouted ? "Test Team A" : "Test Team B", teamID: id,
            colorRGB: rgb.map { RGB(red: $0[0], green: $0[1], blue: $0[2]) }, colorName: name, score: 0)
    }

    private func analysis(_ teams: [TeamSummary]) throws -> GameAnalysis {
        var analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        analysis.teams = teams
        return analysis
    }

    /// The banner's labels for `teams` on the ready game (CSS colour names resolved by the design system).
    private func bannerLabels(_ teams: [TeamSummary]) throws -> [String] {
        try GameDetailTeamChoice.choices(for: analysis(teams), game: Fixture.decode(Game.self, "game_ready.json")).map(\.label)
    }

    // MARK: - When the banner shows

    @Test func theFixtureTeamsGiveNavyAndWhiteJerseys() throws {
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        let game = try Fixture.decode(Game.self, "game_ready.json")  // team_id_map {}

        let choices = GameDetailTeamChoice.choices(for: analysis, game: game)

        #expect(choices.map(\.label) == ["Navy jerseys", "White jerseys"])
        #expect(choices.map(\.swatch) == [HexColor(red: 24, green: 34, blue: 76), HexColor(red: 238, green: 238, blue: 236)])
        #expect(choices.map(\.teamID) == [0, 1])
        #expect(choices.map(\.otherTeamID) == [1, 0])
        #expect(choices.map(\.side) == [.scouted, .other])
        #expect(choices[0].keepsCurrentSides)
        #expect(!choices[1].keepsCurrentSides)
    }

    @Test func theUpdateNamesTheChosenTeamScouted() throws {
        let choices = GameDetailTeamChoice.choices(
            for: try Fixture.decode(GameAnalysis.self, "analysis.json"), game: try Fixture.decode(Game.self, "game_ready.json"))

        let keep = String(decoding: try ScoutJSON.encode(choices[0].update), as: UTF8.self)
        let swap = String(decoding: try ScoutJSON.encode(choices[1].update), as: UTF8.self)

        #expect(keep == #"{"team_id_map":{"0":"scouted","1":"other"}}"#)
        #expect(swap == #"{"team_id_map":{"0":"other","1":"scouted"}}"#)
    }

    @Test func noBannerOnceTheCoachHasChosen() throws {
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        let game = try Fixture.decode(Game.self, "game_patch_team_id_map.json")  // {"0":"scouted","1":"other"}

        #expect(GameDetailTeamChoice.choices(for: analysis, game: game).isEmpty)
    }

    @Test func noBannerUnlessBothTeamsHaveAnIDAndAColour() throws {
        let game = try Fixture.decode(Game.self, "game_ready.json")
        let withoutID = try analysis([team(.scouted, id: 0, name: "navy"), team(.other, id: nil, name: "white")])
        let withoutColour = try analysis([team(.scouted, id: 0, name: "navy"), team(.other, id: 1)])
        let oneTeam = try analysis([team(.scouted, id: 0, name: "navy")])

        #expect(GameDetailTeamChoice.choices(for: withoutID, game: game).isEmpty)
        #expect(GameDetailTeamChoice.choices(for: withoutColour, game: game).isEmpty)
        #expect(GameDetailTeamChoice.choices(for: oneTeam, game: game).isEmpty)
    }

    // MARK: - Labels (game.js:303-316)

    @Test func theColourNameIsCapitalised() throws {
        let labels = try bannerLabels([team(.scouted, id: 0, name: "dark"), team(.other, id: 1, name: "light")])
        #expect(labels == ["Dark jerseys", "Light jerseys"])
    }

    @Test func withoutANameTheWordComesFromTheColour() throws {
        let labels = try bannerLabels([
            team(.scouted, id: 0, rgb: [250, 250, 250]), team(.other, id: 1, rgb: [20, 20, 20]),
        ])
        #expect(labels == ["Light jerseys", "Dark jerseys"])
    }

    @Test func theSameWordIsToldApartByLuminance() throws {
        // #282830 (luminance ≈ 0.022) and #5a2828 (≈ 0.038).
        let labels = try bannerLabels([
            team(.scouted, id: 0, rgb: [40, 40, 48], name: "dark"), team(.other, id: 1, rgb: [90, 40, 40], name: "Dark"),
        ])
        #expect(labels == ["Dark jerseys (darker)", "Dark jerseys (lighter)"])
    }

    @Test func theSameWordAndShadeAreNumbered() throws {
        let labels = try bannerLabels([
            team(.scouted, id: 0, rgb: [40, 40, 48], name: "dark"), team(.other, id: 1, rgb: [40, 40, 48], name: "dark"),
        ])
        #expect(labels == ["Dark jerseys (team 1)", "Dark jerseys (team 2)"])
    }

    @Test func unknownColoursAreNumbered() throws {
        // "royal blue" is not a single CSS colour word, so there is no luminance to compare (game.js: NaN).
        let labels = try bannerLabels([
            team(.scouted, id: 0, name: "royal blue"), team(.other, id: 1, name: "royal blue"),
        ])
        #expect(labels == ["Royal blue jerseys (team 1)", "Royal blue jerseys (team 2)"])
    }

    @Test func shadesWithinTheToleranceAreNumbered() throws {
        // #f3f4f6 ("light") and #f4f4f6 differ by less than 0.005 in luminance.
        let labels = try bannerLabels([
            team(.scouted, id: 0, name: "light"), team(.other, id: 1, rgb: [244, 244, 246], name: "light"),
        ])
        #expect(labels == ["Light jerseys (team 1)", "Light jerseys (team 2)"])
    }

    // MARK: - Swatches and title

    @Test func theSwatchIsTheDetectedColourOrGrey() {
        #expect(GameDetailTeamChoice.swatch(for: team(.scouted, rgb: [24, 34, 76], name: "white")) == HexColor(red: 24, green: 34, blue: 76))
        #expect(GameDetailTeamChoice.swatch(for: team(.scouted, name: "navy")) == HexColor(0x000080))
        #expect(GameDetailTeamChoice.swatch(for: team(.scouted, name: "royal blue")) == HexColor(0x888888))
    }

    @Test func theBannerNamesTheGamesScoutedTeam() {
        #expect(GameDetailText.teamBannerTitle(scoutedTeam: "Test Team A") == "Which team is Test Team A?")
        #expect(GameDetailText.teamBannerHint.hasPrefix("The analysis split the players by jersey colour."))
    }
}
