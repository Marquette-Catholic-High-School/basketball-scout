import SwiftUI

/// One row of a text table: each cell gets its share (`fractions`) of the row's width, the row is as tall
/// as its tallest cell, and cells are top-aligned, so long texts wrap inside their column (a SwiftUI
/// `Table` cannot live inside the game page's scroll view, and `Grid` sizes columns by their unwrapped text).
nonisolated struct ReportColumnsLayout: Layout {
    var fractions: [CGFloat]
    var spacing: CGFloat = Theme.Spacing.medium
    /// The width asked for when the parent proposes none.
    var idealWidth: CGFloat = 720

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? idealWidth
        let widths = columnWidths(total: width, count: subviews.count)
        var height: CGFloat = 0
        for (subview, columnWidth) in zip(subviews, widths) {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(total: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (subview, columnWidth) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: nil))
            x += columnWidth + spacing
        }
    }

    /// The columns' widths: the row's width less the gaps, shared by `fractions` (missing ones count 1).
    func columnWidths(total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let usable = max(0, total - spacing * CGFloat(count - 1))
        let shares = (0..<count).map { $0 < fractions.count ? max(0, fractions[$0]) : 1 }
        let sum = shares.reduce(0, +)
        guard sum > 0 else { return Array(repeating: usable / CGFloat(count), count: count) }
        return shares.map { usable * $0 / sum }
    }
}

/// Buttons side by side that wrap onto the next line when the row is full (iPhone widths, large text),
/// each at its natural size, leading-aligned.
nonisolated struct ReportFlowLayout: Layout {
    var spacing: CGFloat = Theme.Spacing.small
    var lineSpacing: CGFloat = Theme.Spacing.small

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, maxWidth: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = place(subviews, maxWidth: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each subview's frame: left to right, a new line when the next one would not fit. A subview wider
    /// than the row gets the row's width (and wraps its own text).
    func place(_ subviews: Subviews, maxWidth: CGFloat) -> [CGRect] {
        let sizes = subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            guard maxWidth.isFinite, ideal.width > maxWidth else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
        return frames(for: sizes, maxWidth: maxWidth)
    }

    func frames(for sizes: [CGSize], maxWidth: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

/// A bulleted or numbered list of report items (report.js `bulletList`).
struct ReportBulletList: View {
    let items: [String]
    var numbered = false

    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Text(verbatim: numbered ? "\(index + 1)." : "\u{2022}")
                        .monospacedDigit()
                        .frame(minWidth: numbered ? markerWidth : nil, alignment: .trailing)
                        .accessibilityHidden(!numbered)
                    Text(verbatim: item)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A label and a control (a picker) on one line, or the label above the control when the line is too
/// narrow (long team names, a long version title on iPhone); the control then truncates rather than run
/// off the screen. The control carries the accessible label, so the visible one is hidden from VoiceOver.
struct ReportLabeledControl<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Spacing.small) {
                labelText
                control.fixedSize()
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                labelText
                control
            }
        }
    }

    private var labelText: some View {
        Text(verbatim: label)
            .font(.subheadline.weight(.medium))
            .accessibilityHidden(true)
    }
}

/// A labelled block inside a key-player or tendency card ("Strengths", "How to defend").
struct ReportLabeledBlock<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            Text(verbatim: label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The header row of a report table.
struct ReportTableHeader: View {
    let titles: [String]
    let fractions: [CGFloat]

    var body: some View {
        ReportColumnsLayout(fractions: fractions) {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                Text(verbatim: title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Spacing.xSmall)
        .accessibilityHidden(true)
    }
}
