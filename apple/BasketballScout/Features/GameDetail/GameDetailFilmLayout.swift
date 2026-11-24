import SwiftUI

/// Places the film card and the event timeline (03 §7.3 row 7; app.css `.game-layout`). One layout for every
/// arrangement, so switching between them (a Mac window resized, an iPad rotated, the analysis arriving) keeps
/// the film player's identity: the film keeps playing where it was.
///
/// The first subview is the film, the second (optional) the timeline.
struct GameDetailFilmLayout: Layout {
    nonisolated enum Mode: Hashable, Sendable {
        /// Film left, timeline right as tall as the film card (and at least `minimumHeight`); the timeline
        /// fills that height (`.playerTimelineFillsHeight()`).
        case sideBySide(timelineWidth: CGFloat, minimumHeight: CGFloat)
        /// Film on top, the timeline below at its own height (its list is 55 % of the visible height, the web's
        /// `.timeline-scroll { max-height: 55vh }`, plus its filters and footer).
        case stacked
        /// The film alone, at most `maximumWidth` wide (no analysis yet, the web's `solo`).
        case solo(maximumWidth: CGFloat)
    }

    var mode: Mode
    var spacing: CGFloat = GameDetailLayout.spacing

    /// Where the film and the timeline go for a page `width` wide, given the film card's height for a width and
    /// (stacked) the timeline's own height for a width.
    static func arrange(
        mode: Mode, width: CGFloat, spacing: CGFloat, hasTimeline: Bool, filmHeight: (CGFloat) -> CGFloat,
        timelineHeight: (CGFloat) -> CGFloat = { _ in 0 }
    ) -> (film: CGRect, timeline: CGRect?, size: CGSize) {
        let width = max(0, width)
        switch mode {
        case .sideBySide(let timelineWidth, let minimumHeight) where hasTimeline:
            let filmWidth = max(0, width - spacing - timelineWidth)
            let height = filmHeight(filmWidth)
            let rowHeight = max(height, minimumHeight)
            return (
                CGRect(x: 0, y: 0, width: filmWidth, height: height),
                CGRect(x: filmWidth + spacing, y: 0, width: timelineWidth, height: rowHeight),
                CGSize(width: width, height: rowHeight))
        case .stacked where hasTimeline:
            let height = filmHeight(width)
            let timeline = timelineHeight(width)
            return (
                CGRect(x: 0, y: 0, width: width, height: height),
                CGRect(x: 0, y: height + spacing, width: width, height: timeline),
                CGSize(width: width, height: height + spacing + timeline))
        case .solo(let maximumWidth):
            let filmWidth = min(width, maximumWidth)
            let height = filmHeight(filmWidth)
            return (CGRect(x: 0, y: 0, width: filmWidth, height: height), nil, CGSize(width: width, height: height))
        default:
            let height = filmHeight(width)
            return (CGRect(x: 0, y: 0, width: width, height: height), nil, CGSize(width: width, height: height))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        guard let film = subviews.first else { return }
        film.place(
            at: CGPoint(x: bounds.minX + result.film.minX, y: bounds.minY + result.film.minY),
            proposal: ProposedViewSize(width: result.film.width, height: result.film.height))
        if subviews.count > 1 {
            let timeline = subviews[1]
            let frame = result.timeline ?? .zero
            timeline.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (film: CGRect, timeline: CGRect?, size: CGSize) {
        guard let film = subviews.first else { return (.zero, nil, .zero) }
        // Without a width (never in a vertical scroll view) the film's own ideal width is used.
        let available = width ?? film.sizeThatFits(.unspecified).width
        return Self.arrange(
            mode: mode, width: available, spacing: spacing, hasTimeline: subviews.count > 1,
            filmHeight: { filmWidth in film.sizeThatFits(ProposedViewSize(width: filmWidth, height: nil)).height },
            timelineHeight: { timelineWidth in
                subviews.count > 1 ? subviews[1].sizeThatFits(ProposedViewSize(width: timelineWidth, height: nil)).height : 0
            })
    }
}
