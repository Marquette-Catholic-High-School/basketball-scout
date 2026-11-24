import SwiftUI

/// The film and the event timeline (03 §7.3 row 7; app.css `.game-layout`), shown when something can be
/// played or there is an analysis.
///
/// - Film: `FilmPlayerView()` (F-player) when the stored film or the annotated copy can be played; otherwise
///   (an analysis but no film on this server, e.g. a link game) the "Film not available" notice with "Upload
///   the film" (03 §7.7, 04 §6.2). The player is not shown in that case, so its own notice never doubles this one.
/// - Timeline: `EventTimelineView()` (F-player), only with an analysis. Side by side it is as tall as the film
///   card (at least `GameDetailLayout.wideRowMinimumHeight`) and fills that column; stacked it takes its own
///   height (its list is 55 % of the visible height). Either way it scrolls its own rows.
/// - Without an analysis the film stands alone, at most 1100 points wide (the web's `solo`).
///
/// One `GameDetailFilmLayout` arranges all three cases, so the player is never rebuilt by a change of layout.
/// The film carries `filmScrollID` and reports how much of it is visible (`onFilmVisibilityChange`), so the
/// page can bring it into view after a seek from below (06 §7.3 "reveal").
struct GameDetailFilmArea: View {
    let layout: GameDetailLayout
    let onUploadFilm: () -> Void
    /// The film's visibility in the page's scroll view changed.
    var onFilmVisibilityChange: (GameDetailFilmReveal) -> Void = { _ in }

    @Environment(GameContext.self) private var context

    /// The film's id in the page's scroll view (`ScrollViewProxy.scrollTo`).
    static let filmScrollID = "GameDetailFilmArea.film"

    private var mode: GameDetailFilmLayout.Mode {
        guard context.analysis != nil else { return .solo(maximumWidth: GameDetailLayout.soloFilmMaximumWidth) }
        return layout.isWide
            ? .sideBySide(timelineWidth: layout.timelineWidth, minimumHeight: GameDetailLayout.wideRowMinimumHeight)
            : .stacked
    }

    var body: some View {
        let viewportHeight = layout.viewport.height
        GameDetailFilmLayout(mode: mode) {
            film
                .id(Self.filmScrollID)
                .onGeometryChange(for: GameDetailFilmReveal.self) { proxy in
                    GameDetailFilmReveal(filmFrame: proxy.frame(in: .scrollView), viewportHeight: viewportHeight)
                } action: { visibility in
                    onFilmVisibilityChange(visibility)
                }
            if context.analysis != nil {
                EventTimelineView()
                    .playerTimelineFillsHeight(layout.isWide)
            }
        }
    }

    @ViewBuilder
    private var film: some View {
        if context.isPlayable {
            FilmPlayerView()
        } else if let notice = context.filmUnavailableNotice {
            // A live game's film is put together when the stream ends: nothing to upload meanwhile.
            NoticeView(
                tone: ScoutTone(notice.tone), title: notice.title, message: notice.message, hint: notice.hint,
                actions: context.isLive ? [] : [NoticeAction(GameDetailText.uploadTheFilm, perform: onUploadFilm)])
        } else {
            // Not reached (the area shows only with film or an analysis); keeps the film the layout's first subview.
            Color.clear.frame(height: 0)
        }
    }
}

/// Whether the game page scrolls the film into view after a timeline row or an analysis tab asked for a seek
/// (06 §7.3 "reveal"; player.js:240-246): only when the film is not wholly visible; then it is centred when it
/// fits (the web's `block: "center"`), else its top is shown. The page animates it unless Reduce Motion is on.
nonisolated struct GameDetailFilmReveal: Hashable, Sendable {
    /// The film card lies wholly inside the visible part of the page.
    var isWhollyVisible: Bool
    /// The film card fits in the visible height.
    var fits: Bool

    /// Before the first measurement: nothing to do.
    static let unknown = GameDetailFilmReveal(isWhollyVisible: true, fits: true)

    init(isWhollyVisible: Bool, fits: Bool) {
        self.isWhollyVisible = isWhollyVisible
        self.fits = fits
    }

    /// From the film card's frame in the scroll view's visible coordinates and the visible height.
    init(filmFrame: CGRect, viewportHeight: CGFloat) {
        let tolerance: CGFloat = 1
        isWhollyVisible = viewportHeight <= 0
            || (filmFrame.minY >= -tolerance && filmFrame.maxY <= viewportHeight + tolerance)
        fits = filmFrame.height <= viewportHeight
    }

    /// A seek asked for from a list scrolls the film into view.
    var needsScroll: Bool { !isWhollyVisible }

    /// Where the film lands in the visible part of the page.
    var anchor: UnitPoint { fits ? .center : .top }
}
