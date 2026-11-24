import Foundation
import Testing
@testable import BasketballScout

/// The page head and its actions (03 §7.3 row 1, §7.4; game.js `renderHeader`, `showJobStatus`).
@MainActor
struct GameDetailHeaderStateTests {
    private let enUS = Locale(identifier: "en_US")

    // MARK: - Header

    @Test func theHeaderOfAnAnalysedGame() throws {
        let game = try Fixture.decode(Game.self, "game_ready.json")
        let analysis = try Fixture.decode(GameAnalysis.self, "analysis.json")
        let context = GameContext.preview(game: game, analysis: analysis)

        let header = GameDetailHeaderState(
            game: game, analysis: analysis, palette: context.teamPalette, badge: context.headerBadge, locale: enUS)

        #expect(header.title == "Test Team A vs Test Team B")
        #expect(header.scoutedName == "Test Team A")
        #expect(header.otherName == "Test Team B")
        #expect(header.scoutedColor == HexColor(red: 24, green: 34, blue: 76))
        #expect(header.otherColor == HexColor(red: 238, green: 238, blue: 236))
        #expect(header.facts == ["Nov 7, 2026", "Varsity", "Test Arena"])
        #expect(header.badge == BadgeLabel("Ready", tone: .success))
        #expect(header.factsLine == "Nov 7, 2026 \u{00B7} Varsity \u{00B7} Test Arena")
        #expect(header.spokenMeta == "Test Team A versus Test Team B. Nov 7, 2026. Varsity. Test Arena. Status: Ready")
    }

    @Test func factsAreLeftOutWhenNotSet() throws {
        let game = try SessionFixtures.game("game_failed.json") { $0.level = "  " }  // no date or location

        let header = GameDetailHeaderState(
            game: game, analysis: nil, palette: TeamPalette(scoutedHint: game.scoutedColor), badge: game.statusBadge, locale: enUS)

        #expect(header.facts.isEmpty)
        #expect(header.otherName == "Opponent")
        #expect(header.badge == BadgeLabel("Failed", tone: .danger))
        #expect(header.spokenMeta == "Test Team C versus Opponent. Status: Failed")
    }

    @Test func theBadgeFollowsTheRunningJob() throws {
        let context = GameContext.preview(
            game: try Fixture.decode(Game.self, "game_ready.json"),
            jobs: [try Fixture.decode(Job.self, "job_analyze_2_running_downloading_results.json")])
        let model = GameDetailModel(context: context, toasts: nil)

        #expect(model.header?.badge?.text.hasPrefix("Processing \u{00B7} ") == true)
        #expect(model.header?.badge?.tone == .info)
    }

    // MARK: - Actions (03 §7.4)

    @Test func aReadyGameWithGPUResults() throws {
        let actions = GameDetailActionState(game: try Fixture.decode(Game.self, "game_ready.json"), isBusy: false, isStarting: false)

        #expect(actions.filmTitle == "Replace film")
        #expect(actions.rerunTitle == "Re-run analysis")
        #expect(actions.rerunKind == .reanalyze)
        #expect(actions.canRerun)
        #expect(actions.rerunHelp == "Redo the stats on this server (about a minute, no GPU)")
        #expect(actions.rerunToast == "Re-running the analysis\u{2026}")
        #expect(actions.showsFullReanalysis)
        #expect(actions.canFullReanalysis)
        #expect(actions.fullReanalysisHelp == "Send the film to the GPU again")
    }

    @Test func whileAnAnalysisRunsBothButtonsAreDisabledAndSaySo() throws {
        let byStatus = GameDetailActionState(game: try Fixture.decode(Game.self, "game_queued.json"), isBusy: true, isStarting: false)
        let byPolledJob = GameDetailActionState(game: try Fixture.decode(Game.self, "game_ready.json"), isBusy: true, isStarting: false)

        for actions in [byStatus, byPolledJob] {
            #expect(!actions.canRerun)
            #expect(actions.rerunHelp == "An analysis is already running")
            #expect(actions.showsFullReanalysis)
            #expect(!actions.canFullReanalysis)
            #expect(actions.fullReanalysisHelp == "An analysis is already running")
        }
    }

    @Test func whileAJobIsBeingStartedTheButtonsWait() throws {
        let actions = GameDetailActionState(game: try Fixture.decode(Game.self, "game_ready.json"), isBusy: false, isStarting: true)

        #expect(!actions.canRerun)
        #expect(!actions.canFullReanalysis)
        #expect(actions.rerunHelp == "Redo the stats on this server (about a minute, no GPU)")
    }

    @Test func aGameWithoutFilm() throws {
        let actions = GameDetailActionState(game: try Fixture.decode(Game.self, "game_get.json"), isBusy: false, isStarting: false)

        #expect(actions.filmTitle == "Add film")
        #expect(actions.rerunTitle == "Analyze film")
        #expect(actions.rerunKind == .analyze)
        #expect(!actions.canRerun)
        #expect(actions.rerunHelp == nil)
        #expect(!actions.showsFullReanalysis)
    }

    @Test func filmNotAnalysedYetCanBeAnalysed() throws {
        let game = try SessionFixtures.game("game_get.json") {
            $0.status = .uploaded
            $0.hasVideo = true
            $0.videoFilename = "test-film.mp4"
        }

        let actions = GameDetailActionState(game: game, isBusy: false, isStarting: false)

        #expect(actions.rerunTitle == "Analyze film")
        #expect(actions.canRerun)
        #expect(actions.rerunHelp == nil)
        #expect(actions.rerunToast == "Analysis started")
        #expect(!actions.showsFullReanalysis)
    }

    @Test func aLinkGameHasFilmToSendAgain() throws {
        let actions = GameDetailActionState(game: try Fixture.decode(Game.self, "game_link_ready.json"), isBusy: false, isStarting: false)

        #expect(actions.filmTitle == "Replace film")
        #expect(actions.showsFullReanalysis)
        #expect(actions.canRerun)
    }

    @Test func gpuResultsWithoutFilmCanStillBeRerun() throws {
        // has_tracking alone allows a REANALYZE (03 §7.4: hasFilm || has_tracking); Full re-analysis needs the film.
        let game = try SessionFixtures.game("game_ready.json") {
            $0.hasVideo = false
            $0.videoURL = nil
        }

        let actions = GameDetailActionState(game: game, isBusy: false, isStarting: false)

        #expect(actions.canRerun)
        #expect(actions.filmTitle == "Add film")
        #expect(!actions.showsFullReanalysis)
    }
}
