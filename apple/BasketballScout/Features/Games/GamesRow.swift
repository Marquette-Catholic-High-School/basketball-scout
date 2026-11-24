import SwiftUI

/// One game in the games list (07 §3.4): a stripe in the scouted team's jersey hint colour, the display
/// title (and the matchup under a custom title), the badges, date · level · location, the film's name, a
/// failed analysis's message, and the progress of the analysis (07 §3.6) or of this device's upload.
/// Games without film get an "Add film" button; the other actions (Open, Roster, Delete) are in the
/// list's context menu, swipe actions and the Mac's Delete key.
///
/// Everything it shows is in `GamesRowModel`, a plain value, so polling redraws only rows that changed.
struct GamesRow: View {
    let model: GamesRowModel
    /// "Add film" (shown while the game has no film and nothing uploads).
    let onAddFilm: () -> Void

    @ScaledMetric(relativeTo: .headline) private var stripeWidth: CGFloat = 4
    @ScaledMetric(relativeTo: .headline) private var stripeGap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            info
                .opacity(model.isDeleting ? 0.55 : 1)
                .accessibilityElement(children: .combine)
            if model.isDeleting {
                deleting
            } else if model.filmAction == .addFilm {
                GamesAddFilmButton(action: onAddFilm)
                    .accessibilityLabel(Text(verbatim: "Add film to \(model.title)"))
            }
        }
        .padding(.leading, stripeWidth + stripeGap)
        .overlay(alignment: .leading) { stripe }
        .padding(.vertical, Theme.Spacing.xSmall)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(verbatim: model.title)
                .font(.headline)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let matchup = model.matchup {
                Text(verbatim: matchup)
                    .font(.subheadline)
                    .modifier(GamesMutedText())
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GamesBadgeFlow(spacing: Theme.Spacing.xSmall + 2) {
                ForEach(Array(model.badges.enumerated()), id: \.offset) { _, badge in
                    StatusBadge(text: badge.text, tone: badge.tone, systemImage: badge.systemImage)
                }
            }
            .padding(.vertical, Theme.Spacing.xxSmall)
            if let details = model.details {
                Text(verbatim: details)
                    .font(.footnote)
                    .modifier(GamesMutedText())
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let film = model.film {
                Text(verbatim: film)
                    .font(.footnote)
                    .modifier(GamesMutedText())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: film))
            }
            if let liveLine = model.liveLine {
                Text(verbatim: liveLine)
                    .font(.footnote)
                    .modifier(GamesMutedText())
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorLine = model.errorLine {
                Text(verbatim: errorLine)
                    .font(.footnote)
                    .modifier(GamesMutedText())
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let analysis = model.analysis {
                GamesProgressLine(progress: analysis)
                    .padding(.top, Theme.Spacing.xxSmall)
            }
            if let upload = model.upload {
                GamesProgressLine(progress: upload)
                    .padding(.top, Theme.Spacing.xxSmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deleting: some View {
        HStack(spacing: Theme.Spacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(verbatim: "Deleting\u{2026}")
        }
        .font(.footnote)
        .modifier(GamesMutedText())
        .accessibilityElement(children: .combine)
    }

    /// The web's 6 px card border in the jersey hint colour (its border colour when there is none), with a
    /// hairline so "light" and "dark" stay visible on any background.
    private var stripe: some View {
        let shape = RoundedRectangle(cornerRadius: stripeWidth / 2, style: .continuous)
        return shape
            .fill(model.stripe?.color ?? Theme.separator)
            .overlay(shape.strokeBorder(Theme.separator, lineWidth: 0.5))
            .frame(width: stripeWidth)
            .accessibilityHidden(true)
    }
}

extension GamesRow: Equatable {
    /// Rows compare by what they show (use `.equatable()`), so a poll that changes nothing in a row does
    /// not redraw it; the action closure is the same for the same game.
    nonisolated static func == (lhs: GamesRow, rhs: GamesRow) -> Bool {
        lhs.model == rhs.model
    }
}

/// A progress line over its bar (07 §3.6): the text first, as on the web's card, then the bar.
private struct GamesProgressLine: View {
    let progress: GamesRowProgress

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            // Its own height for the width: next to the bar's GeometryReader a stack would give it one line.
            Text(verbatim: progress.text)
                .font(.footnote)
                .monospacedDigit()
                .modifier(GamesMutedText())
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            switch progress.bar {
            case .none:
                EmptyView()
            case .indeterminate:
                ScoutProgressBar(fraction: nil)
                    .accessibilityRepresentation {
                        ProgressView(progress.accessibilityLabel)
                    }
            case .value(let fraction):
                ScoutProgressBar(fraction: min(max(fraction, 0), 1))
                    .accessibilityRepresentation {
                        ProgressView(progress.accessibilityLabel, value: min(max(fraction, 0), 1))
                    }
            }
        }
    }
}

/// "Add film" under a game without film: compact, with a full 44-point touch target on iOS. In a
/// selected sidebar row (brand-coloured background) it switches to the row's text colour.
private struct GamesAddFilmButton: View {
    let action: () -> Void

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Button(action: action) {
            Label {
                Text(verbatim: GamesFilmAction.addFilm.title)
            } icon: {
                Image(systemName: "plus.circle.fill")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.brandText))
            #if os(iOS)
            .frame(minHeight: Theme.Layout.minimumTapTarget)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(Text(verbatim: "Upload the game film or give a video link"))
    }
}

/// Muted text (the web's `--text-muted`), or the system's secondary colour inside a selected row, where
/// the fixed grey would not be readable on the selection colour.
struct GamesMutedText: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.secondaryText))
    }
}

/// Badges side by side, wrapping onto more lines when the row is narrow or the text is large (the web's
/// wrapping meta row).
private struct GamesBadgeFlow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        GamesFlowLayout(spacing: spacing) { content }
    }
}

/// Places subviews left to right and starts a new line when the next one does not fit.
nonisolated private struct GamesFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + spacing
        }
    }

    nonisolated private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> [Line] {
        let maxWidth = width ?? .infinity
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > maxWidth {
                // A badge wider than the row wraps its own text.
                size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }
            if !line.items.isEmpty, line.width + spacing + size.width > maxWidth {
                lines.append(line)
                line = Line()
            }
            line.width += (line.items.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.items.append((index, size))
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}

#if DEBUG
#Preview("Rows") {
    List {
        ForEach(GamesPreviewData.rowSamples()) { row in
            GamesRow(model: row) {}
        }
    }
    #if os(macOS)
    .frame(width: 340, height: 900)
    #endif
}

#Preview("Rows – dark, large type") {
    List {
        ForEach(GamesPreviewData.rowSamples().prefix(4)) { row in
            GamesRow(model: row) {}
        }
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
    #if os(macOS)
    .frame(width: 340, height: 900)
    #endif
}
#endif
