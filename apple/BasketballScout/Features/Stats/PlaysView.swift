import SwiftUI

/// The plays tab (06 §11; plays.js): for each team the "Offense" and "Defense" play-type tables (count,
/// share of possessions, points, points per possession, field goals, turnovers; zone shapes for zone
/// defenses), then "Individual plays" with the Type and Team filters, or the possessions. Tapping a play or
/// a possession plays the film from 1 s before it starts (`PlaybackCoordinator.seek(toPlayStartingAt:)`).
/// Filters are remembered for the game while the app runs. Lives in the game page's scrolling column and
/// draws its own card.
struct PlaysView: View {
    @Environment(GameContext.self) private var context
    @State private var availableWidth: CGFloat = 0
    /// The play or possession watched last (highlighted).
    @State private var watchedID: String?
    @ScaledMetric(relativeTo: .subheadline) private var columnScale: CGFloat = 1

    private let memory = StatsMemory.shared

    init() {}

    var body: some View {
        StatsAnalysisContent(title: "Plays", systemImage: "list.bullet.rectangle") { analysis in
            content(analysis)
        }
    }

    @ViewBuilder
    private func content(_ analysis: GameAnalysis) -> some View {
        let gameID = context.gameID
        let sortedPlays = StatsPlaysModel.sortedPlays(analysis.plays)
        let typeOptions = StatsPlaysModel.typeOptions(sortedPlays)
        let filters = StatsPlaysModel.validated(memory.playsFilters(for: gameID), typeOptions: typeOptions)
        let binding = Binding<StatsPlaysFilters>(
            get: { filters },
            set: { memory.setPlaysFilters($0, for: gameID) })
        Card(title: "Plays") {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                summary(analysis)
                Divider()
                listHeader(binding: binding, typeOptions: typeOptions)
                switch filters.list {
                case .plays:
                    playList(sortedPlays, filters: filters)
                case .possessions:
                    possessionList(analysis, side: filters.possessionSide)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            availableWidth = width
        }
    }

    // MARK: Play types

    @ViewBuilder
    private func summary(_ analysis: GameAnalysis) -> some View {
        let blocks = StatsPlaysModel.summaryBlocks(analysis)
        if blocks.isEmpty {
            StatsHint(StatsPlaysModel.noPlaysText)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if isWide && blocks.count == 2 {
                    HStack(alignment: .top, spacing: Theme.Spacing.xLarge) {
                        ForEach(blocks) { block in
                            summaryBlock(block).frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                } else {
                    ForEach(blocks) { block in summaryBlock(block) }
                }
                StatsHint(StatsPlaysModel.summaryHint)
            }
        }
    }

    private func summaryBlock(_ block: StatsPlaySummaryBlock) -> some View {
        let name = context.teamName(block.side)
        return VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                StatsTeamSwatch(color: context.teamColor(block.side))
                SectionTitle(name, level: .subsection)
            }
            StatsPlaySummaryGrid(teamName: name, offense: block.offense, defense: block.defense)
        }
    }

    // MARK: Lists

    private func listHeader(binding: Binding<StatsPlaysFilters>, typeOptions: [PlayType]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    SectionTitle(listTitle(binding.wrappedValue.list), level: .subsection)
                    Spacer()
                    listPicker(binding)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    SectionTitle(listTitle(binding.wrappedValue.list), level: .subsection)
                    listPicker(binding)
                }
            }
            StatsFlowLayout(horizontalSpacing: Theme.Spacing.large) {
                if binding.wrappedValue.list == .plays {
                    StatsFilterPicker(
                        title: "Type", selection: binding.type,
                        options: [StatsFilterOption(value: nil, title: "All play types")]
                            + typeOptions.map { StatsFilterOption(value: $0, title: $0.label) })
                    StatsFilterPicker(title: "Team", selection: binding.side, options: teamOptions)
                } else {
                    StatsFilterPicker(title: "Team", selection: binding.possessionSide, options: teamOptions)
                }
            }
        }
    }

    private func listPicker(_ binding: Binding<StatsPlaysFilters>) -> some View {
        Picker(selection: binding.list) {
            ForEach(StatsPlaysListMode.allCases) { mode in
                Text(verbatim: mode.title).tag(mode)
            }
        } label: {
            Text(verbatim: "Show")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func listTitle(_ mode: StatsPlaysListMode) -> String {
        mode == .plays ? "Individual plays" : "Possessions"
    }

    /// "Both teams", then each team by name (plays.js `buildFilters`).
    private var teamOptions: [StatsFilterOption<TeamSide?>] {
        [
            StatsFilterOption(value: nil, title: "Both teams"),
            StatsFilterOption(value: .scouted, title: context.teamName(.scouted)),
            StatsFilterOption(value: .other, title: context.teamName(.other)),
        ]
    }

    @ViewBuilder
    private func playList(_ sortedPlays: [Play], filters: StatsPlaysFilters) -> some View {
        let rows = StatsPlaysModel.rows(sortedPlays, filters: filters)
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if rows.isEmpty {
                StatsHint(StatsPlaysModel.emptyText(totalPlays: sortedPlays.count))
            } else {
                if isWide { playHeader }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        StatsPlayRowView(row: row, isWide: isWide, isCurrent: watchedID == row.id, columns: columns) {
                            watchedID = row.id
                            context.playback.seek(toPlayStartingAt: row.startT)
                        }
                        Divider()
                    }
                }
            }
            StatsHint(StatsPlaysModel.countText(shown: rows.count, total: sortedPlays.count))
        }
    }

    /// The wide list's column headings (plays.js table head).
    private var playHeader: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(verbatim: "Time").frame(width: columns.time, alignment: .leading)
            Text(verbatim: "Play").frame(width: columns.play, alignment: .leading)
            Text(verbatim: "Team").frame(width: columns.team, alignment: .leading)
            Text(verbatim: "Players").frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "Outcome").frame(width: columns.outcome, alignment: .leading)
            Text(verbatim: "Pts").frame(width: columns.points, alignment: .trailing)
            Text(verbatim: "Conf.").frame(width: columns.confidence, alignment: .trailing)
                .help("Confidence")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, Theme.Spacing.xSmall)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func possessionList(_ analysis: GameAnalysis, side: TeamSide?) -> some View {
        let rows = StatsPlaysModel.possessionRows(analysis, side: side)
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if rows.isEmpty {
                StatsHint(StatsPlaysModel.possessionEmptyText(total: analysis.possessions.count))
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        let id = "poss\(row.id)"
                        StatsPossessionRowView(row: row, isWide: isWide, isCurrent: watchedID == id, columns: columns) {
                            watchedID = id
                            context.playback.seek(toPlayStartingAt: row.startT)
                        }
                        Divider()
                    }
                }
            }
            StatsHint(StatsPlaysModel.possessionCountText(shown: rows.count, total: analysis.possessions.count))
        }
    }

    // MARK: Layout

    /// The web's table columns when there is room; two-line rows on phones.
    private var isWide: Bool { availableWidth >= 760 }

    private var columns: StatsPlayColumns { StatsPlayColumns().scaled(by: columnScale) }
}

#if DEBUG
#Preview("Stats – Plays") {
    StatsPreviewScreen {
        PlaysView()
    }
}

#Preview("Stats – Plays – dark, large text") {
    StatsPreviewScreen {
        PlaysView()
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.xxxLarge)
}
#endif
