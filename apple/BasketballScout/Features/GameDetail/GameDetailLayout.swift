import CoreGraphics

/// How the game page arranges itself for the space it has (03 §7.3 row 7; 07 §10.6; app.css `.game-layout`).
///
/// - Wide (iPad and Mac with room): the film and the event timeline side by side (the web's ≥ 1100 px rule,
///   measured on the content column instead of the window, since the sidebar takes its share), the timeline
///   as tall as the film card and at least `wideRowMinimumHeight`, and the analysis tabs below.
/// - Compact (iPhone, narrow windows): everything stacked; the timeline takes its own height (its list is 55 %
///   of the visible height, the web's `.timeline-scroll { max-height: 55vh }`) and scrolls its own rows.
/// - Film without an analysis yet (the web's `solo`): the film alone, at most `soloFilmMaximumWidth` wide.
nonisolated struct GameDetailLayout: Hashable, Sendable {
    /// The page never grows wider than the web's `main` (1440 px).
    static let maximumContentWidth: CGFloat = 1440
    /// From this content width on, film and timeline sit side by side.
    static let wideMinimumWidth: CGFloat = 900
    /// The film alone is at most this wide (`.game-layout.solo { max-width: 1100px }`).
    static let soloFilmMaximumWidth: CGFloat = 1100
    /// The timeline column's share of the width, and its limits (the web's `minmax(380px, 1fr)` next to `1.25fr`,
    /// a little narrower here so the film gets the room in a split view).
    static let timelineShare: CGFloat = 0.36
    static let timelineWidthRange: ClosedRange<CGFloat> = 320...440
    /// The side-by-side row is at least this tall, so a short film card (the "Film not available" notice)
    /// still leaves room for the timeline.
    static let wideRowMinimumHeight: CGFloat = 440
    /// Space between the page's sections and columns (web 1rem).
    static let spacing: CGFloat = 16
    /// From this window width on, iPad toolbar buttons show their titles next to their icons.
    static let toolbarTitlesMinimumWidth: CGFloat = 1000

    /// The visible size of the page (the scroll view).
    var viewport: CGSize
    /// The page's margin on each side.
    var horizontalPadding: CGFloat

    init(viewport: CGSize, horizontalPadding: CGFloat = GameDetailLayout.spacing) {
        self.viewport = viewport
        self.horizontalPadding = horizontalPadding
    }

    /// The width the sections get.
    var contentWidth: CGFloat {
        max(0, min(viewport.width - 2 * horizontalPadding, Self.maximumContentWidth))
    }

    /// Film and timeline side by side.
    var isWide: Bool { contentWidth >= Self.wideMinimumWidth }

    /// The timeline column's width when side by side.
    var timelineWidth: CGFloat {
        min(max(contentWidth * Self.timelineShare, Self.timelineWidthRange.lowerBound), Self.timelineWidthRange.upperBound)
    }

    /// The film column's width when side by side.
    var filmWidth: CGFloat {
        max(0, contentWidth - Self.spacing - timelineWidth)
    }

    /// iPad toolbar buttons have room for their titles.
    var toolbarShowsTitles: Bool { viewport.width >= Self.toolbarTitlesMinimumWidth }
}
