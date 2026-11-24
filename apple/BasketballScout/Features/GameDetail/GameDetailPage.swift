import SwiftUI

/// The game page's sections, top to bottom (03 §7.3): header, page error area, the live banner of a live game
/// (docs/LIVE.md), job panel, "Which team is …?"
/// banner, "No film yet" card (or this device's film upload in its place), pending-analysis notice, film +
/// event timeline, analysis tabs. Reads the page's `GameContext` and `GameDetailModel` from the environment.
///
/// Layout (`GameDetailLayout`): on iPad and Mac with room the film and the timeline sit side by side with the
/// tabs below; on iPhone and in narrow windows everything is stacked. The header actions are toolbar buttons
/// on iPad and Mac and one menu on iPhone (`GameDetailToolbarActions`). Pull to refresh (iOS), the toolbar's
/// Refresh (Mac) and ⌘R (the app's Game menu) reload the page.
///
/// When a timeline row or an analysis tab asks for a seek and the film is not wholly visible, the page
/// scrolls it into view (06 §7.3 "reveal"; `GameDetailFilmReveal`), without animation under Reduce Motion.
struct GameDetailPage: View {
    @Environment(GameContext.self) private var context
    @Environment(GameDetailModel.self) private var model
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// The visible size of the page.
    @State private var viewport: CGSize = .zero
    /// How much of the film is visible (for the reveal after a seek).
    @State private var filmReveal = GameDetailFilmReveal.unknown
    /// Where the header's title ends, in the page's content (iOS: the title moves to the bar once it scrolled away).
    @State private var titleBottom: CGFloat = 0
    @State private var isTitleScrolledAway = false

    private static let contentSpace = "GameDetailPage.content"

    private var layout: GameDetailLayout { GameDetailLayout(viewport: viewport) }

    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact || !layout.isWide
        #else
        !layout.isWide
        #endif
    }

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: GameDetailLayout.spacing) {
                    sections
                }
                .frame(maxWidth: GameDetailLayout.maximumContentWidth, alignment: .leading)
                .padding(GameDetailLayout.spacing)
                .frame(maxWidth: .infinity)
                .coordinateSpace(.named(Self.contentSpace))
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                viewport = size
            }
            #if os(iOS)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > max(titleBottom, 1)
            } action: { _, scrolledAway in
                isTitleScrolledAway = scrolledAway
            }
            #endif
            // 06 §7.3: a timeline row asked to see the film, or a tab (shot chart, plays) asked for a seek.
            .onChange(of: context.isPlayable ? context.playerRevealRequests : 0) { _, _ in
                revealFilm(proxy)
            }
            .onChange(of: context.playback.pendingSeek) { _, seek in
                if seek != nil { revealFilm(proxy) }
            }
            .scoutPageBackground()
            .navigationTitle(model.header?.title ?? GameDetailText.untitled)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .navigationSubtitle(model.header?.factsLine ?? "")
            #endif
            .toolbar { toolbar }
            .refreshable { await model.refresh() }
            .confirmAction($model.confirmation)
        }
    }

    /// Brings the film into view when it is not wholly visible (centred when it fits, else its top).
    private func revealFilm(_ proxy: ScrollViewProxy) {
        guard context.isPlayable, filmReveal.needsScroll else { return }
        let anchor = filmReveal.anchor
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            proxy.scrollTo(GameDetailFilmArea.filmScrollID, anchor: anchor)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var sections: some View {
        if let header = model.header {
            GameDetailHeader(state: header, coordinateSpace: Self.contentSpace) { bottom in
                titleBottom = bottom
            }
            pageErrorArea
            LiveBanner()
            GameDetailJobPanel()
            teamBanner
            GameDetailFilmUploadSlot(gameID: context.gameID, showsNoFilmCard: context.showsNoFilmCard) {
                appModel.navigate(to: .film)
            }
            if let pending = context.pendingNotice {
                GameDetailPendingNotice(notice: pending)
            }
            if context.isShowingCachedAnalysis && !context.isLoadingAnalysis {
                GameDetailCachedAnalysisNote()
            }
            if context.isPlayable || context.analysis != nil {
                GameDetailFilmArea(layout: layout) {
                    appModel.navigate(to: .film)
                } onFilmVisibilityChange: { visibility in
                    filmReveal = visibility
                }
            }
            if context.analysis != nil {
                GameDetailAnalysisTabs(prefersPills: isCompact)
            }
        } else if model.pageError != nil {
            pageErrorArea
        } else {
            LoadingView(text: GameDetailText.loadingGame)
                .frame(minHeight: 240)
        }
    }

    /// 03 §7.3 row 2: one error box, the newest problem.
    @ViewBuilder
    private var pageErrorArea: some View {
        switch model.pageError {
        case .load(let error, let canGoBack)?:
            ErrorBox(error: error, actions: loadErrorActions(error, canGoBack: canGoBack))
        case .action(let error)?:
            ErrorBox(error: error)
        case nil:
            EmptyView()
        }
    }

    /// "Try again" when retrying can help, "Back to games" when there is no game to show (game.js:104-108).
    private func loadErrorActions(_ error: any PresentableError, canGoBack: Bool) -> [NoticeAction] {
        var actions: [NoticeAction] = []
        if error.isRetryable {
            actions.append(NoticeAction(GameDetailText.tryAgain, isPrimary: true) {
                Task { await model.refresh() }
            })
        }
        if canGoBack {
            actions.append(NoticeAction(GameDetailText.backToGames) {
                appModel.selectedGameID = nil
            })
        }
        return actions
    }

    @ViewBuilder
    private var teamBanner: some View {
        let choices = model.teamChoices
        if let game = context.game, !choices.isEmpty {
            GameDetailTeamBanner(choices: choices, scoutedTeam: game.scoutedTeam, accent: context.teamColor(.scouted))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .principal) {
            GameDetailNavigationTitle(title: model.header?.title ?? "", isVisible: isTitleScrolledAway)
        }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            GameDetailToolbarActions(style: toolbarStyle)
        }
    }

    private var toolbarStyle: GameDetailToolbarActions.Style {
        #if os(iOS)
        horizontalSizeClass == .compact ? .menu : .buttons(showsTitles: layout.toolbarShowsTitles)
        #else
        .buttons(showsTitles: true)
        #endif
    }
}

/// iOS: the page title in the navigation bar, shown once the header's own title has scrolled away (the
/// header shows the full title, wrapped, at the top of the page).
private struct GameDetailNavigationTitle: View {
    let title: String
    let isVisible: Bool

    var body: some View {
        Text(verbatim: title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isVisible)
            .accessibilityHidden(!isVisible)
    }
}

// MARK: - Previews

#Preview("GameDetail – ready") {
    GameDetailPreviewData.page(GameContext.preview(
        game: GameDetailPreviewData.game(), analysis: GameDetailPreviewData.analysis(),
        jobs: [GameDetailPreviewData.job(status: .succeeded, stage: .done, progress: 100, message: "Analysis complete")]))
}

#Preview("GameDetail – analysis running") {
    GameDetailPreviewData.page(GameContext.preview(
        game: GameDetailPreviewData.game(status: .processing), analysis: GameDetailPreviewData.analysis(),
        jobs: [GameDetailPreviewData.job(
            status: .running, stage: .gpuProcessing, progress: 42, message: "Demo mode: simulating GPU processing (43%)")],
        health: GameDetailPreviewData.health()))
}

#Preview("GameDetail – queued, no worker") {
    GameDetailPreviewData.page(GameContext.preview(
        game: GameDetailPreviewData.game(status: .queued, hasAnalysis: false, hasTracking: false),
        jobs: [GameDetailPreviewData.job(status: .queued, stage: .queued, progress: 0, message: "Waiting for a worker", started: false)],
        health: GameDetailPreviewData.health(workerLastSeen: nil)))
}

#Preview("GameDetail – failed past the GPU") {
    GameDetailPreviewData.page(GameContext.preview(
        game: GameDetailPreviewData.game(status: .failed, hasAnalysis: false, error: GameDetailPreviewData.failure),
        jobs: [GameDetailPreviewData.job(
            status: .failed, stage: .analyzing, progress: 93, message: "Analysis failed", error: GameDetailPreviewData.failure)]))
}

#Preview("GameDetail – which team") {
    GameDetailPreviewData.page(GameContext.preview(
        game: GameDetailPreviewData.game(teamIDMap: [:]), analysis: GameDetailPreviewData.analysis(),
        jobs: [GameDetailPreviewData.job(
            status: .succeeded, stage: .done, progress: 100, message: "Analysis complete",
            warnings: ["Scouting report not generated: Claude is not configured"])]))
}

#Preview("GameDetail – no film yet") {
    GameDetailPreviewData.page(GameContext.preview(
        game: GameDetailPreviewData.game(status: .draft, hasVideo: false, hasAnalysis: false, hasTracking: false)))
}

#Preview("GameDetail – film not analysed, dark, large type") {
    GameDetailPreviewData.page(GameContext.preview(
        game: GameDetailPreviewData.game(status: .uploaded, hasAnalysis: false, hasTracking: false)))
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}

#Preview("GameDetail – link film, cancelled re-run") {
    GameDetailPreviewData.page(GameContext.preview(
        game: GameDetailPreviewData.game(hasVideo: false, videoURL: "https://example.com/films/test-film.mp4"),
        analysis: GameDetailPreviewData.analysis(),
        jobs: [GameDetailPreviewData.job(kind: .reanalyze, status: .cancelled, stage: .done, progress: 10, message: "Cancelled")]))
}
