import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The box score as a native sortable `Table` (iPad and Mac, 09 R50): the web's 19 columns, player rows in
/// the chosen order, then the team line and the totals, which never move.
///
/// The table sits in the game page's scrolling column, so it is exactly as tall as its rows (measured for
/// the Mac's bordered table: 28 pt header, 24 pt rows, a 1 pt border); on iPad rows follow Dynamic Type.
/// Header clicks only report the column; `StatsBoxScoreSort` applies the web's rule (the active column
/// flips, another starts at its first direction).
struct StatsBoxScoreTable: View {
    let model: StatsBoxScoreModel
    @Binding var sort: StatsBoxScoreSort
    /// The width the table may take (iPad: it scrolls sideways when its columns need more).
    let availableWidth: CGFloat
    /// "Show shots" for a player row (nil: not offered).
    let showShots: ((StatsBoxScoreRow) -> Void)?

    @State private var selection = Set<StatsBoxScoreRow.ID>()
    /// Which columns show, their order and widths, as the coach arranged them (the header's menu); kept on
    /// this device for every game.
    @AppStorage(Self.columnsStorageKey) private var storedColumns = Data()
    /// Column widths follow the text size.
    @ScaledMetric(relativeTo: .subheadline) private var widthUnit: CGFloat = 1
    #if os(iOS)
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 44
    #endif

    var body: some View {
        let rows = model.rows(sortedBy: sort)
        Table(of: StatsBoxScoreRow.self, selection: $selection, sortOrder: sortOrder, columnCustomization: columnCustomization) {
            TableColumnForEach(StatsBoxScoreColumn.allCases) { column in
                TableColumn(
                    Text(verbatim: column.title).accessibilityLabel(column.name),
                    sortUsing: StatsBoxScoreComparator(column: column, order: column.firstSortAscending ? .forward : .reverse)
                ) { row in
                    StatsBoxScoreCell(row: row, column: column)
                }
                .width(min: width(column).min * widthUnit, ideal: width(column).ideal * widthUnit, max: width(column).max.map { $0 * widthUnit })
                .alignment(column.isNumeric ? .numeric : .leading)
                .customizationID(column.rawValue)
                .disabledCustomizationBehavior(column == .player ? .visibility : [])
            }
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
            }
        }
        .contextMenu(forSelectionType: StatsBoxScoreRow.ID.self) { ids in
            menu(for: ids, in: rows)
        }
        #if os(macOS)
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .onCopyCommand {
            let selected = rows.filter { selection.contains($0.id) }
            guard !selected.isEmpty else { return [] }
            return [NSItemProvider(object: StatsBoxScoreModel.tabSeparated(selected) as NSString)]
        }
        .frame(height: height(rows: rows.count))
        #else
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        // iPadOS tables do not scroll sideways: give the columns their room and scroll the whole table.
        .frame(width: max(availableWidth, requiredWidth), height: height(rows: rows.count))
        .statsHorizontalScroll()
        #endif
        .accessibilityLabel(Text(verbatim: model.caption))
    }

    // MARK: Columns

    /// Where the column arrangement is kept (UserDefaults, this device only).
    static let columnsStorageKey = "org.marquettecatholic.BasketballScout.stats.boxScoreColumns"

    private var columnCustomization: Binding<TableColumnCustomization<StatsBoxScoreRow>> {
        Binding(
            get: { (try? JSONDecoder().decode(TableColumnCustomization<StatsBoxScoreRow>.self, from: storedColumns)) ?? TableColumnCustomization() },
            set: { storedColumns = (try? JSONEncoder().encode($0)) ?? Data() })
    }

    // MARK: Sorting

    /// The Table's sort indicator shows `sort`; a header click calls the setter with that column first
    /// (flipped when it was already first).
    private var sortOrder: Binding<[StatsBoxScoreComparator]> {
        Binding(
            get: {
                guard let column = sort.column else { return [] }
                return [StatsBoxScoreComparator(column: column, order: sort.ascending ? .forward : .reverse)]
            },
            set: { newValue in
                guard let first = newValue.first else { return }
                if first.column == sort.column {
                    sort.ascending = first.order == .forward
                } else {
                    sort.select(first.column)
                }
            })
    }

    // MARK: Context menu

    @ViewBuilder
    private func menu(for ids: Set<StatsBoxScoreRow.ID>, in rows: [StatsBoxScoreRow]) -> some View {
        let chosen = rows.filter { ids.contains($0.id) }
        if chosen.count == 1, let row = chosen.first, row.kind == .player, row.line.fga > 0, let showShots {
            Button {
                showShots(row)
            } label: {
                Label("Show shots", systemImage: "basketball")
            }
        }
        if !chosen.isEmpty {
            Button {
                ScoutPasteboard.copy(StatsBoxScoreModel.tabSeparated(chosen))
            } label: {
                Label(chosen.count == 1 ? "Copy row" : "Copy rows", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: Size

    /// The height that shows every row without scrolling inside the table.
    private func height(rows count: Int) -> CGFloat {
        #if os(macOS)
        // Measured: header 28, rows 24 (13 pt text + 8), 1 pt border above and below. Classic scroll bars
        // take 15 pt at the bottom when the columns do not fit.
        let scroller: CGFloat = NSScroller.preferredScrollerStyle == .legacy ? 16 : 0
        return 28 + 24 * CGFloat(count) + 2 + scroller + 1
        #else
        return rowHeight * CGFloat(count + 1) + Theme.Spacing.small
        #endif
    }

    /// The width the columns need at their ideal sizes, with each column's padding.
    private var requiredWidth: CGFloat {
        StatsBoxScoreColumn.allCases.reduce(0) { $0 + (width($1).ideal + Self.columnPadding) * widthUnit }
    }

    /// Room around each column's content (iPadOS).
    private static let columnPadding: CGFloat = 16

    /// Column widths in points at the default text size (min, ideal, max): wide enough for the widest
    /// value in bold ("100.0%", "11-23", "Team / unidentified") and the header.
    private func width(_ column: StatsBoxScoreColumn) -> (min: CGFloat, ideal: CGFloat, max: CGFloat?) {
        #if os(macOS)
        let scale: CGFloat = 1
        #else
        let scale: CGFloat = 1.1
        #endif
        let base: (CGFloat, CGFloat, CGFloat?) = switch column {
        case .jersey: (24, 28, 44)
        case .player: (130, 170, 280)
        case .minutes: (34, 38, 60)
        case .fieldGoals, .threePointers, .freeThrows: (42, 46, 64)
        case .fieldGoalPercent, .threePointPercent, .freeThrowPercent: (50, 54, 70)
        case .offensiveRebounds, .defensiveRebounds: (36, 40, 56)
        default: (28, 32, 52)
        }
        return (base.0 * scale, base.1 * scale, base.2.map { $0 * scale })
    }
}

/// One cell: the web's text, muted for "did not play" rows and the team line (italic), bold for totals.
private struct StatsBoxScoreCell: View {
    let row: StatsBoxScoreRow
    let column: StatsBoxScoreColumn

    var body: some View {
        Text(verbatim: row.text(column))
            #if os(iOS)
            .font(.subheadline)
            #endif
            .lineLimit(1)
            .monospacedDigit()
            .fontWeight(row.kind == .totals ? .bold : nil)
            .italic(row.kind == .team)
            .foregroundStyle(row.isDNP || row.kind == .team ? Theme.secondaryText : Color.primary)
            .statsIf(row.isDNP) { $0.help(StatsBoxScoreRow.didNotPlayHelp) }
            .accessibilityLabel(Text(verbatim: row.spokenText(column)))
    }
}

/// The comparator behind each column's header (the Table needs one per sortable column). Sorting itself
/// is done by `StatsBoxScoreModel.sorted`, so the team and totals lines stay at the bottom.
nonisolated struct StatsBoxScoreComparator: SortComparator, Hashable, Sendable {
    var column: StatsBoxScoreColumn
    var order: SortOrder

    func compare(_ lhs: StatsBoxScoreRow, _ rhs: StatsBoxScoreRow) -> ComparisonResult {
        let result = StatsBoxScoreModel.compare(lhs.sortValue(column), rhs.sortValue(column), locale: .current)
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

private extension View {
    /// Inside a sideways scroll view that only scrolls when the content is wider than the screen.
    func statsHorizontalScroll() -> some View {
        ScrollView(.horizontal) {
            self
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}
