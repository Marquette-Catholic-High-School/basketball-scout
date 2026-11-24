import SwiftUI

/// Places views in rows and starts a new row when one is full, like the web's `flex-wrap` header meta line
/// (app.css `.game-header-meta`): team chips, date, level, location and the status badge wrap at large text
/// sizes and on narrow screens instead of being cut off. Items in a row are centred vertically.
struct GameDetailFlowLayout: Layout {
    /// Space between items in a row.
    var spacing: CGFloat = Theme.Spacing.small
    /// Space between rows.
    var lineSpacing: CGFloat = Theme.Spacing.xSmall + 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        return Self.arrange(sizes: sizes, maxWidth: width, spacing: spacing, lineSpacing: lineSpacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
        let arrangement = Self.arrange(sizes: sizes, maxWidth: bounds.width, spacing: spacing, lineSpacing: lineSpacing)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// The frames of items of `sizes` laid out in rows no wider than `maxWidth` (an item wider than that gets a
    /// row of its own, narrowed to `maxWidth`), and the size of the whole.
    nonisolated static func arrange(
        sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat, lineSpacing: CGFloat
    ) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var rows: [(range: Range<Int>, height: CGFloat)] = []
        var rowStart = 0
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let width = min(size.width, maxWidth)
            if index > rowStart, x + spacing + width > maxWidth {
                rows.append((rowStart..<index, rowHeight))
                rowStart = index
                x = 0
                rowHeight = 0
            }
            let left = index == rowStart ? 0 : x + spacing
            frames.append(CGRect(x: left, y: 0, width: width, height: size.height))
            x = left + width
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x)
        }
        if rowStart < sizes.count { rows.append((rowStart..<sizes.count, rowHeight)) }
        var y: CGFloat = 0
        for (number, row) in rows.enumerated() {
            if number > 0 { y += lineSpacing }
            for index in row.range {
                frames[index].origin.y = y + (row.height - frames[index].height) / 2
            }
            y += row.height
        }
        return (frames, CGSize(width: widest, height: y))
    }
}
