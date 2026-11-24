import Foundation
import SwiftUI
import Testing
@testable import BasketballScout

/// The app's menus for the key window's game page (Game, File > Print…, Playback): titles and enabled states
/// by the same rules as the page's own buttons (03 §7.4, the player's toolbar), and what each command does.
@MainActor
struct GamePageMenuTests {
    private func focus(
        game: Game = GameDetailPreviewData.game(), analysis: GameAnalysis? = GameDetailPreviewData.analysis(),
        jobs: [Job] = [], reports: [ReportRecord] = []
    ) -> GamePageFocus {
        let context = GameContext.preview(game: game, analysis: analysis, jobs: jobs, reports: reports)
        return GamePageFocus(context: context, model: GameDetailModel(context: context, toasts: nil))
    }

    @Test func withoutAGamePageEverythingIsDisabled() {
        let menu = GamePageMenuState.none
        #expect(!menu.canOpenRoster && !menu.canRerun && !menu.canFullReanalysis && !menu.showsTabs)
        #expect(!menu.canPrintReport && !menu.canPlay && !menu.canStep && !menu.canJumpToEvents)
        #expect(menu.rerunTitle == "Re-run Analysis")
        #expect(menu.playTitle == "Play")
    }

    @Test func aReadyGameOffersItsActions() {
        let menu = focus().menu
        #expect(menu.canOpenRoster)
        #expect(menu.rerunTitle == "Re-run Analysis")
        #expect(menu.canRerun)
        #expect(menu.canFullReanalysis)
        #expect(menu.showsTabs)
    }

    @Test func theRerunTitleFollowsTheGame() {
        let menu = focus(game: GameDetailPreviewData.game(status: .uploaded, hasAnalysis: false, hasTracking: false), analysis: nil).menu
        #expect(menu.rerunTitle == "Analyze Film")
        #expect(menu.canRerun)
        #expect(!menu.canFullReanalysis)  // the page offers it only with GPU results
        #expect(!menu.showsTabs)  // no analysis, no tabs
    }

    @Test func whileAnAnalysisRunsTheStartsWait() {
        let running = GameDetailPreviewData.job(status: .running, stage: .gpuProcessing, progress: 42, message: "Analyzing")
        let menu = focus(game: GameDetailPreviewData.game(status: .processing), jobs: [running]).menu
        #expect(menu.canOpenRoster)
        #expect(!menu.canRerun)
        #expect(!menu.canFullReanalysis)
        #expect(menu.showsTabs)
    }

    @Test func theTabsAreOnCommand1To6() {
        #expect(GameTab.allCases.map(\.menuTitle) == ["Box Score", "Shot Chart", "Plays", "Scouting Report", "Exports", "Data Quality"])
        #expect(GameTab.allCases.map(\.shortcutKey) == ["1", "2", "3", "4", "5", "6"].map { KeyEquivalent(Character($0)) })
        let page = focus()
        page.show(.plays)
        #expect(page.context.selectedTab == .plays)
        #expect(page.menu.selectedTab == .plays)
    }

    /// File > Print… prints the report the Report tab shows; on another tab there is nothing to print.
    @Test func printFollowsTheReportTab() throws {
        let reports = try Fixture.decode([ReportRecord].self, "reports_list_seeded.json")
        let page = focus(reports: reports)
        page.show(.boxScore)
        #expect(!page.menu.canPrintReport)
        #expect(page.context.reportOnScreen == nil)
        page.show(.report)
        #expect(page.context.reportOnScreen?.id == reports.first?.id)
        #expect(page.menu.canPrintReport == ReportPrinter.isAvailable)
        page.show(.boxScore)
    }

    @Test func playbackFollowsThePlayer() {
        func menu(_ player: GamePageMenuState.Player?) -> GamePageMenuState {
            GamePageMenuState(actions: nil, hasAnalysis: true, selectedTab: .boxScore, canPrintReport: false, player: player)
        }
        let loading = menu(GamePageMenuState.Player(acceptsCommands: false, isPlaying: false, hasEvents: true))
        #expect(!loading.canPlay && !loading.canStep)
        #expect(loading.canJumpToEvents)  // as the toolbar's "◀ Event" / "Event ▶"
        let playing = menu(GamePageMenuState.Player(acceptsCommands: true, isPlaying: true, hasEvents: false))
        #expect(playing.canPlay && playing.canStep && !playing.canJumpToEvents)
        #expect(playing.playTitle == "Pause")
        #expect(!menu(nil).canPlay)
        // A page whose film is not loaded yet: the player's commands wait.
        #expect(!focus().menu.canPlay)
    }
}
