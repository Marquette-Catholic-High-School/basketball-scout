import SwiftUI

/// The game page of the key window, for the app's menus (`AppCommands`: Game, File > Print…, Playback). The
/// page publishes it with `.focusedSceneValue(\.gamePage, …)` while it is the top screen of its window, so
/// the menus follow the window the coach is working in; every command does what the page's own button does.
struct GamePageFocus {
    let context: GameContext
    let model: GameDetailModel

    /// What the menus show and allow, by the page's own rules.
    var menu: GamePageMenuState {
        var player: GamePageMenuState.Player?
        if context.isPlayable {
            let controller = context.playerController
            player = GamePageMenuState.Player(
                acceptsCommands: controller.acceptsCommands, isPlaying: context.playback.isPlaying,
                hasEvents: !context.playerTimeline.markers.isEmpty)
        }
        return GamePageMenuState(
            actions: model.actions, hasAnalysis: context.analysis != nil, selectedTab: context.selectedTab,
            canPrintReport: context.reportOnScreen != nil && ReportPrinter.isAvailable, player: player)
    }

    // MARK: - Game menu

    /// "Re-run Analysis" / "Analyze Film" (no question, as the page's button).
    func rerun() {
        Task { await model.rerun() }
    }

    /// "Full Re-analysis…": the page asks first.
    func requestFullReanalysis() {
        model.requestFullReanalysis()
    }

    /// ⌘1–⌘6.
    func show(_ tab: GameTab) {
        context.selectedTab = tab
    }

    /// File > Print… (⌘P): the report the Report tab shows.
    func printReport() {
        context.printReportOnScreen()
    }

    // MARK: - Playback menu (the player's toolbar and keys, 07 §9)

    func togglePlay() {
        context.playerController.togglePlay()
    }

    func step(by seconds: Double) {
        context.playerController.step(by: seconds)
    }

    func previousEvent() {
        context.playerController.goToPreviousEvent(in: context.playerTimeline.markers)
    }

    func nextEvent() {
        context.playerController.goToNextEvent(in: context.playerTimeline.markers)
    }
}

extension FocusedValues {
    /// The key window's game page, while it is the top screen of its window (`GameView`).
    @Entry var gamePage: GamePageFocus?
}

/// The menus' titles and enabled states for one game page, by the same rules as the page's buttons (03 §7.4,
/// the player's toolbar). Without a page (another screen on top, no game selected) everything is disabled.
nonisolated struct GamePageMenuState: Hashable, Sendable {
    /// The film player's state (nil when nothing can be played).
    nonisolated struct Player: Hashable, Sendable {
        /// A film is loaded and not being calibrated (the toolbar's step buttons, Space).
        var acceptsCommands: Bool
        var isPlaying: Bool
        /// The timeline has events to jump to ("◀ Event" / "Event ▶").
        var hasEvents: Bool
    }

    /// Roster & Jerseys: the game is loaded.
    var canOpenRoster: Bool
    /// "Re-run Analysis" (REANALYZE) or "Analyze Film" (ANALYZE, no GPU results yet).
    var rerunTitle: String
    var canRerun: Bool
    /// The page offers Full re-analysis (film and GPU results), and it is not busy.
    var canFullReanalysis: Bool
    /// The analysis tabs are on the page (⌘1–⌘6).
    var showsTabs: Bool
    var selectedTab: GameTab
    /// The Report tab shows a report that can be printed.
    var canPrintReport: Bool
    var canPlay: Bool
    var isPlaying: Bool
    var canStep: Bool
    var canJumpToEvents: Bool

    /// Everything disabled (no game page in the key window).
    static let none = GamePageMenuState(actions: nil, hasAnalysis: false, selectedTab: .defaultTab, canPrintReport: false, player: nil)

    init(actions: GameDetailActionState?, hasAnalysis: Bool, selectedTab: GameTab, canPrintReport: Bool, player: Player?) {
        canOpenRoster = actions != nil
        rerunTitle = actions?.rerunKind == .analyze ? "Analyze Film" : "Re-run Analysis"
        canRerun = actions?.canRerun ?? false
        canFullReanalysis = actions?.canFullReanalysis ?? false
        showsTabs = hasAnalysis
        self.selectedTab = selectedTab
        self.canPrintReport = canPrintReport
        canPlay = player?.acceptsCommands ?? false
        isPlaying = player?.isPlaying ?? false
        canStep = player?.acceptsCommands ?? false
        canJumpToEvents = player?.hasEvents ?? false
    }

    /// "Play" or "Pause", by what the film is doing.
    var playTitle: String { isPlaying ? "Pause" : "Play" }
}

extension GameTab {
    /// The tab's menu item (title case, as menu items are): "Box Score" … "Data Quality".
    var menuTitle: String {
        switch self {
        case .boxScore: "Box Score"
        case .shotChart: "Shot Chart"
        case .plays: "Plays"
        case .report: "Scouting Report"
        case .exports: "Exports"
        case .dataQuality: "Data Quality"
        }
    }

    /// ⌘1–⌘6 in the tabs' order.
    var shortcutKey: KeyEquivalent {
        KeyEquivalent(Character(String((GameTab.allCases.firstIndex(of: self) ?? 0) + 1)))
    }
}
