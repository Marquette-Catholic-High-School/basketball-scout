import SwiftUI

/// The box score on narrow screens (iPhone, iPad in a narrow window or with very large text): one row per
/// player with the main numbers, a sort menu with the web's rule, and the full line in a sheet.
struct StatsBoxScoreList: View {
    let model: StatsBoxScoreModel
    @Binding var sort: StatsBoxScoreSort
    let teamName: String
    let teamColor: HexColor
    /// "Show shots" for a player row (nil: not offered).
    let showShots: ((StatsBoxScoreRow) -> Void)?

    @State private var detail: StatsBoxScoreRow?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            sortMenu
            VStack(spacing: 0) {
                let rows = model.rows(sortedBy: sort)
                ForEach(rows) { row in
                    if row.kind == .team, !model.hasPlayers {
                        Text(verbatim: StatsBoxScoreModel.emptyPlayersMessage)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Theme.Spacing.small)
                        Divider()
                    }
                    Button {
                        detail = row
                    } label: {
                        StatsBoxScoreListRow(row: row, highlighted: highlightedColumn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(verbatim: "Shows the full line"))
                    if row.id != rows.last?.id { Divider() }
                }
            }
        }
        .sheet(item: $detail) { row in
            StatsBoxScorePlayerSheet(row: row, teamName: teamName, teamColor: teamColor, showShots: showShotsAction(for: row))
        }
    }

    /// "Show shots on the chart" for a player who took shots.
    private func showShotsAction(for row: StatsBoxScoreRow) -> (() -> Void)? {
        guard let showShots, row.kind == .player, row.line.fga > 0 else { return nil }
        return { showShots(row) }
    }

    /// The stat shown on the right of each row: the sort column when it is a stat, else points.
    private var highlightedColumn: StatsBoxScoreColumn {
        if let column = sort.column, column.isNumeric { return column }
        return .points
    }

    private var sortMenu: some View {
        Menu {
            Button {
                sort = .serverOrder
            } label: {
                if sort.column == nil {
                    Label(Self.serverOrderTitle, systemImage: "checkmark")
                } else {
                    Text(verbatim: Self.serverOrderTitle)
                }
            }
            Divider()
            ForEach(StatsBoxScoreColumn.allCases) { column in
                Button {
                    sort.select(column)
                } label: {
                    if sort.column == column {
                        Label(column.name, systemImage: sort.ascending ? "arrow.up" : "arrow.down")
                    } else {
                        Text(verbatim: column.name)
                    }
                }
            }
        } label: {
            Label {
                Text(verbatim: "Sort: \(sortTitle)")
            } icon: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .font(.subheadline)
        }
        .accessibilityLabel(Text(verbatim: "Sort players"))
        .accessibilityValue(Text(verbatim: sortTitle))
    }

    private var sortTitle: String {
        guard let column = sort.column else { return Self.serverOrderTitle }
        return "\(column.name), \(sort.ascending ? "lowest first" : "highest first")"
    }

    /// The server's order: roster players by jersey, then unrostered jerseys.
    static let serverOrderTitle = "Roster order"
}

/// One player in the narrow box score: jersey, name, the highlighted stat, and a line of shooting and
/// rebounding numbers.
private struct StatsBoxScoreListRow: View {
    let row: StatsBoxScoreRow
    let highlighted: StatsBoxScoreColumn

    @ScaledMetric(relativeTo: .body) private var jerseyWidth: CGFloat = 34

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(verbatim: row.jersey.isEmpty ? "" : "#\(row.jersey)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .frame(width: jerseyWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: row.name)
                    .fontWeight(row.kind == .totals ? .bold : .medium)
                    .italic(row.kind == .team)
                Text(verbatim: secondLine)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: highlightText)
                .font(.subheadline.monospacedDigit())
                .fontWeight(row.kind == .totals ? .bold : .semibold)
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .foregroundStyle(row.isDNP || row.kind == .team ? Theme.secondaryText : Color.primary)
        .padding(.vertical, Theme.Spacing.small)
        .frame(minHeight: Theme.Layout.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenLabel))
    }

    private var highlightText: String {
        row.isDNP && highlighted == .points ? StatsBoxScoreRow.didNotPlayText : "\(row.text(highlighted)) \(highlighted.title)"
    }

    /// "6-13 FG · 0-2 3PT · 0-0 FT · 4 REB · 2 AST" (points first when another stat is on the right), or
    /// "Did not play".
    private var secondLine: String {
        if row.isDNP { return StatsBoxScoreRow.didNotPlayHelp }
        var columns: [StatsBoxScoreColumn] = [.fieldGoals, .threePointers, .freeThrows, .rebounds, .assists]
        if highlighted != .points { columns.insert(.points, at: 0) }
        return columns.filter { $0 != highlighted }.map { "\(row.text($0)) \($0.title)" }.joined(separator: ScoutFormat.separator)
    }

    private var spokenLabel: String {
        var parts = [row.jersey.isEmpty ? row.name : "Number \(row.jersey), \(row.name)"]
        if row.isDNP {
            parts.append(StatsBoxScoreRow.didNotPlayHelp)
        } else {
            let columns: [StatsBoxScoreColumn] = [.points, .fieldGoals, .threePointers, .freeThrows, .rebounds, .assists]
            let shown = columns.contains(highlighted) ? columns : [highlighted] + columns
            parts += shown.map { "\($0.name) \(row.spokenText($0))" }
        }
        return parts.joined(separator: ", ")
    }
}

/// A player's (or the team's, or the totals') whole line: every box score column with its name, and the
/// shooting by zone.
struct StatsBoxScorePlayerSheet: View {
    let row: StatsBoxScoreRow
    let teamName: String
    let teamColor: HexColor
    /// Switches to the shot chart with this player (nil: not offered).
    let showShots: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Theme.Spacing.small) {
                        Chip(text: teamName, team: teamColor)
                        if row.isDNP {
                            StatusBadge(text: StatsBoxScoreRow.didNotPlayHelp, tone: .neutral)
                        }
                    }
                }
                section("Overview", [.minutes, .points, .plusMinus])
                section("Shooting", [.fieldGoals, .fieldGoalPercent, .threePointers, .threePointPercent, .freeThrows, .freeThrowPercent])
                section("Rebounds", [.offensiveRebounds, .defensiveRebounds, .rebounds])
                section("Other stats", [.assists, .steals, .blocks, .turnovers, .fouls])
                Section {
                    let zones = StatsBoxScoreZoneRow(id: row.id, kind: row.kind, name: row.name, zones: row.line.zones)
                    ForEach(StatsBoxScoreZoneRow.zones, id: \.self) { zone in
                        KeyValueRow(label: zone.boxScoreColumnLabel, value: zones.text(zone), monospacedDigits: true)
                            .accessibilityLabel(Text(verbatim: "\(zone.boxScoreColumnLabel): \(zones.spokenText(zone))"))
                    }
                } header: {
                    Text(verbatim: "Shooting by zone")
                }
                if let showShots {
                    Section {
                        Button {
                            dismiss()
                            showShots()
                        } label: {
                            Label("Show shots on the chart", systemImage: "basketball")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: row.title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
        #endif
    }

    private func section(_ title: String, _ columns: [StatsBoxScoreColumn]) -> some View {
        Section {
            ForEach(columns) { column in
                KeyValueRow(label: column.name, value: row.text(column), monospacedDigits: true)
                    .accessibilityLabel(Text(verbatim: "\(column.name): \(row.spokenText(column))"))
                    .statsIf(column == .minutes) { $0.help(StatsBoxScoreColumn.minutes.help ?? "") }
            }
        } header: {
            Text(verbatim: title)
        }
    }
}
