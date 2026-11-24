import SwiftUI

/// The box score tab (06 §9; boxscore.js): one team at a time (team switch, scouted team first), every
/// player line with the web's 19 columns and exact numbers, the team line and the totals, the summary
/// line and "Shooting by zone".
///
/// iPad and Mac: a sortable `Table` (09 R50). iPhone, narrow iPad windows and accessibility text sizes:
/// a list with a sort menu and each line in a sheet. Sorting follows the web (# and Player ascending
/// first, stats descending; jersey "0" before "00"); the team and the sort are remembered for the game
/// while the app runs. Lives in the game page's scrolling column and draws its own card.
struct BoxScoreView: View {
    @Environment(GameContext.self) private var context
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var availableWidth: CGFloat = 0

    private let memory = StatsMemory.shared

    init() {}

    var body: some View {
        StatsAnalysisContent(title: "Box score", systemImage: "tablecells") { analysis in
            content(analysis)
        }
    }

    @ViewBuilder
    private func content(_ analysis: GameAnalysis) -> some View {
        let gameID = context.gameID
        let remembered = memory.boxScore(for: gameID)
        let side = StatsBoxScoreModel.side(in: analysis, preferred: remembered.side ?? .scouted)
        Card(title: "Box score") {
            if let side, let box = analysis.boxScore(side) {
                let model = StatsBoxScoreModel(box: box)
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    if usesTable {
                        if !model.hasPlayers {
                            Text(verbatim: StatsBoxScoreModel.emptyPlayersMessage)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        StatsBoxScoreTable(
                            model: model, sort: sortBinding(gameID), availableWidth: max(0, availableWidth - 2 * Theme.Spacing.large),
                            showShots: { showShots($0, side: side) })
                    } else {
                        StatsBoxScoreList(
                            model: model, sort: sortBinding(gameID), teamName: box.teamName, teamColor: context.teamColor(side),
                            showShots: { showShots($0, side: side) })
                    }
                    summary(model, side: side)
                    SectionTitle("Shooting by zone", level: .subsection)
                    StatsBoxScoreZoneTable(rows: model.zoneRows)
                        .frame(maxWidth: 680, alignment: .leading)
                    StatsHint(StatsBoxScoreModel.hint + " " + sortHint)
                }
            } else {
                Text(verbatim: StatsBoxScoreModel.noBoxScoreMessage)
                    .foregroundStyle(Theme.secondaryText)
            }
        } trailing: {
            if analysis.boxScores.count > 1, let side {
                teamPicker(analysis, selection: side, gameID: gameID)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            availableWidth = width
        }
    }

    // MARK: Parts

    /// One button per box score, the web's team switch (`aria-pressed` toggles): a segmented control.
    private func teamPicker(_ analysis: GameAnalysis, selection: TeamSide, gameID: String) -> some View {
        Picker(selection: Binding(
            get: { selection },
            set: { side in
                var state = memory.boxScore(for: gameID)
                state.side = side
                memory.setBoxScore(state, for: gameID)
            })
        ) {
            ForEach(analysis.boxScores) { box in
                Text(verbatim: box.teamName).tag(box.side)
            }
        } label: {
            Text(verbatim: "Team")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// Team chip and "Points: 25", "Possessions: 24", "Points per possession: 1.04".
    private func summary(_ model: StatsBoxScoreModel, side: TeamSide) -> some View {
        StatsFlowLayout(horizontalSpacing: Theme.Spacing.large) {
            HStack(spacing: Theme.Spacing.xSmall) {
                StatsTeamSwatch(color: context.teamColor(side))
                Text(verbatim: model.box.teamName)
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityElement(children: .combine)
            ForEach(model.summary) { item in
                StatsSummaryItem(label: item.label, value: item.value)
            }
        }
    }

    /// The last sentence of the hint, for this layout ("Click a column to sort." on the web).
    private var sortHint: String {
        #if os(macOS)
        "Click a column to sort; Control-click a column heading to choose the columns."
        #else
        usesTable ? "Tap a column heading to sort." : "Tap a player for the full line."
        #endif
    }

    // MARK: State

    /// A table needs room: always on the Mac; on iPad in a regular-width window with room for 19 columns
    /// and text below the accessibility sizes.
    private var usesTable: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
            && (availableWidth == 0 || availableWidth >= Self.minimumTableWidth)
        #endif
    }

    /// Below this width (points) the iPad shows the list instead of the 19-column table (wider tables than
    /// the screen scroll sideways).
    static let minimumTableWidth: CGFloat = 700

    private func sortBinding(_ gameID: String) -> Binding<StatsBoxScoreSort> {
        Binding(
            get: { memory.boxScore(for: gameID).sort },
            set: { sort in
                var state = memory.boxScore(for: gameID)
                state.sort = sort
                memory.setBoxScore(state, for: gameID)
            })
    }

    /// "Show shots": the shot chart tab with this player's team and only their shots.
    private func showShots(_ row: StatsBoxScoreRow, side: TeamSide) {
        guard let key = row.shotChartPlayerKey else { return }
        memory.showShots(of: key, side: side, gameID: context.gameID)
        context.selectedTab = .shotChart
    }
}

#if DEBUG
#Preview("Stats – Box score") {
    StatsPreviewScreen {
        BoxScoreView()
    }
}

#Preview("Stats – Box score – dark, large text") {
    StatsPreviewScreen {
        BoxScoreView()
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility1)
}

#Preview("Stats – Box score – nobody identified") {
    StatsPreviewScreen(analysis: StatsPreviewData.analysis(identifiedPlayers: false)) {
        BoxScoreView()
    }
}
#endif
