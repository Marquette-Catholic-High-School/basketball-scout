import SwiftUI

/// One team's play-type tables (plays.js `summaryTable`): "Offense" and "Defense" sections with the
/// columns Count | % Poss | PTS | PPP | FG | TO, in one grid so the columns line up. Scrolls sideways when
/// it does not fit.
struct StatsPlaySummaryGrid: View {
    /// The team's name, for VoiceOver ("Test Team A offense").
    let teamName: String
    let offense: [StatsPlaySummaryRow]
    let defense: [StatsPlaySummaryRow]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) {
                grid.padding(.bottom, Theme.Spacing.xSmall)
            }
        }
    }

    private struct Section: Identifiable {
        let heading: String
        let rows: [StatsPlaySummaryRow]
        var id: String { heading }
    }

    private var sections: [Section] {
        [Section(heading: PlayCategory.offense.label, rows: offense), Section(heading: PlayCategory.defense.label, rows: defense)]
            .filter { !$0.rows.isEmpty }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.medium, verticalSpacing: Theme.Spacing.small) {
            ForEach(sections) { section in
                GridRow {
                    Text(verbatim: section.heading)
                    ForEach(StatsPlaySummaryRow.columnTitles, id: \.self) { title in
                        Text(verbatim: title).gridColumnAlignment(.trailing)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(teamName) \(section.heading.lowercased())"))
                .accessibilityAddTraits(.isHeader)
                Divider()
                ForEach(section.rows) { row in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: row.title)
                            if let shapes = row.shapes {
                                Text(verbatim: "(\(shapes))")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                            Text(verbatim: value).monospacedDigit()
                        }
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: spokenLabel(row)))
                }
            }
        }
    }

    private func spokenLabel(_ row: StatsPlaySummaryRow) -> String {
        var title = row.title
        if let shapes = row.shapes { title += " (\(shapes))" }
        let cells = zip(StatsPlaySummaryRow.columnNames, row.values).map { "\($0) \($1 == ScoutFormat.placeholder ? "none" : $1)" }
        return ([title] + cells).joined(separator: ", ")
    }
}

/// The column widths of the plays and possessions lists (the list scales them with the text size).
struct StatsPlayColumns: Hashable {
    var time: CGFloat = 58
    var play: CGFloat = 170
    var team: CGFloat = 130
    var outcome: CGFloat = 96
    var points: CGFloat = 40
    var confidence: CGFloat = 52

    /// The widths at `scale` × the default text size.
    func scaled(by scale: CGFloat) -> StatsPlayColumns {
        StatsPlayColumns(
            time: time * scale, play: play * scale, team: team * scale, outcome: outcome * scale, points: points * scale,
            confidence: confidence * scale)
    }
}

/// One play of "Individual plays" (plays.js `drawList`). Wide: the web's columns Time | Play | Team |
/// Players | Outcome | Pts | Conf.; narrow: the same facts on two or three lines. Tap or click to watch the
/// play from 1 s before it starts; plays under 50 % confidence are faded.
struct StatsPlayRowView: View {
    let row: StatsPlayRow
    let isWide: Bool
    let isCurrent: Bool
    let columns: StatsPlayColumns
    let watch: () -> Void

    var body: some View {
        Button(action: watch) {
            Group {
                if isWide { wide } else { narrow }
            }
            .opacity(row.isLowConfidence ? 0.55 : 1)
            .modifier(StatsListRowChrome(isCurrent: isCurrent))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spokenLabel))
        }
        .buttonStyle(.plain)
        .help(row.description)
        .accessibilityHint(Text(verbatim: "Plays the film from this play"))
        .contextMenu {
            Button(action: watch) {
                Label(row.watchLabel, systemImage: "play.fill")
            }
            if !row.description.isEmpty {
                Button {
                    ScoutPasteboard.copy(row.description)
                } label: {
                    Label("Copy description", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var wide: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            timeLabel.frame(width: columns.time, alignment: .leading)
            Text(verbatim: row.title)
                .fontWeight(.medium)
                .frame(width: columns.play, alignment: .leading)
            StatsTeamChip(side: row.side)
                .frame(width: columns.team, alignment: .leading)
            Text(verbatim: row.players)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: row.outcome)
                .frame(width: columns.outcome, alignment: .leading)
            Text(verbatim: row.points)
                .monospacedDigit()
                .frame(width: columns.points, alignment: .trailing)
            Text(verbatim: row.confidence)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .frame(width: columns.confidence, alignment: .trailing)
        }
        .font(.subheadline)
    }

    private var narrow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            timeLabel.frame(width: columns.time, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Text(verbatim: row.title).fontWeight(.medium)
                    Spacer(minLength: Theme.Spacing.small)
                    StatsTeamChip(side: row.side)
                }
                if !row.players.isEmpty {
                    Text(verbatim: row.players)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
                Text(verbatim: narrowFacts)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .font(.subheadline)
    }

    private var timeLabel: some View {
        Label {
            Text(verbatim: row.time).monospacedDigit()
        } icon: {
            Image(systemName: "play.circle")
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline.monospaced())
        .foregroundStyle(Color.brandText)
    }

    /// "Made FG · 2 pts · 70%".
    private var narrowFacts: String {
        ScoutFormat.joined([row.outcome, row.points.isEmpty ? nil : "\(row.points) pts", row.confidence])
    }

    private var spokenLabel: String {
        var parts = [ScoutFormat.spokenClock(row.startT), row.title]
        if let side = row.side, side.isKnown { parts.append(side == .scouted ? "scouted team" : "opponent") }
        if !row.players.isEmpty { parts.append(row.players) }
        if row.outcome != ScoutFormat.placeholder { parts.append(row.outcome) }
        if !row.points.isEmpty { parts.append("\(row.points) points") }
        parts.append("confidence \(row.confidence)")
        return parts.joined(separator: ", ")
    }
}

/// One possession: number, team, start time, length, outcome and points, how it started and the plays run.
/// Tap or click to watch it from 1 s before it starts.
struct StatsPossessionRowView: View {
    let row: StatsPossessionRow
    let isWide: Bool
    let isCurrent: Bool
    let columns: StatsPlayColumns
    let watch: () -> Void

    var body: some View {
        Button(action: watch) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Label {
                    Text(verbatim: row.time).monospacedDigit()
                } icon: {
                    Image(systemName: "play.circle")
                }
                .labelStyle(.titleAndIcon)
                .font(.subheadline.monospaced())
                .foregroundStyle(Color.brandText)
                .frame(width: columns.time, alignment: .leading)
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Text(verbatim: row.title).fontWeight(.medium)
                        if row.isTransition {
                            StatusBadge(text: "Transition", tone: .neutral)
                        }
                        Spacer(minLength: Theme.Spacing.small)
                        StatsTeamChip(side: row.side)
                    }
                    Text(verbatim: facts)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                    if let plays = row.plays {
                        Text(verbatim: plays)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .font(.subheadline)
            .modifier(StatsListRowChrome(isCurrent: isCurrent))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spokenLabel))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: "Plays the film from this possession"))
        .contextMenu {
            Button(action: watch) {
                Label(row.watchLabel, systemImage: "play.fill")
            }
        }
    }

    /// "18 s · Made FG · 2 pts · after def rebound".
    private var facts: String {
        ScoutFormat.joined([
            row.length, row.outcome == ScoutFormat.placeholder ? nil : row.outcome,
            row.points > 0 ? "\(row.points) pts" : nil, row.startReason.map { "after \($0)" },
        ])
    }

    private var spokenLabel: String {
        var parts = [row.title, ScoutFormat.spokenClock(row.startT), row.length]
        if let side = row.side, side.isKnown { parts.append(side == .scouted ? "scouted team" : "opponent") }
        if row.outcome != ScoutFormat.placeholder { parts.append(row.outcome) }
        if row.points > 0 { parts.append("\(row.points) points") }
        if let reason = row.startReason { parts.append("after \(reason)") }
        if row.isTransition { parts.append("transition") }
        if let plays = row.plays { parts.append(plays) }
        return parts.joined(separator: ", ")
    }
}

/// The look of a tappable list row: padding, a 44 pt touch target on iPhone and iPad, the watched row
/// tinted, and a hover highlight with a pointer (Mac, iPad with a trackpad).
private struct StatsListRowChrome: ViewModifier {
    let isCurrent: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, Theme.Spacing.small)
            .padding(.horizontal, Theme.Spacing.xSmall)
            .frame(maxWidth: .infinity, minHeight: Self.minimumHeight, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isCurrent { return Color.brand.opacity(0.14) }
        return isHovered ? Theme.insetBackground : .clear
    }

    #if os(macOS)
    private static let minimumHeight: CGFloat = 28
    #else
    private static let minimumHeight: CGFloat = Theme.Layout.minimumTapTarget
    #endif
}
