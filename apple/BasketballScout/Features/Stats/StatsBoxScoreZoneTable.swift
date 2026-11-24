import SwiftUI

/// "Shooting by zone" (boxscore.js `zoneTable`): Player | Paint | Mid-range | 3-point | No location for the
/// players who played, the team line and the totals. Scrolls sideways when it does not fit.
struct StatsBoxScoreZoneTable: View {
    let rows: [StatsBoxScoreZoneRow]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) {
                grid
                    .padding(.bottom, Theme.Spacing.xSmall)
            }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.large, verticalSpacing: Theme.Spacing.small) {
            GridRow {
                Text(verbatim: "Player")
                ForEach(StatsBoxScoreZoneRow.zones, id: \.self) { zone in
                    Text(verbatim: zone.boxScoreColumnLabel)
                        .gridColumnAlignment(.trailing)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.secondaryText)
            .accessibilityHidden(true)

            Divider()

            ForEach(rows) { row in
                GridRow {
                    Text(verbatim: row.name)
                        .fontWeight(row.kind == .totals ? .bold : nil)
                        .italic(row.kind == .team)
                        .lineLimit(1)
                    ForEach(StatsBoxScoreZoneRow.zones, id: \.self) { zone in
                        Text(verbatim: row.text(zone))
                            .monospacedDigit()
                            .fontWeight(row.kind == .totals ? .bold : nil)
                            .lineLimit(1)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(row.kind == .team ? Theme.secondaryText : Color.primary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: spokenLabel(row)))
                if row.kind == .team { Divider() }
            }
        }
    }

    /// "Test Player 1: Paint 3 of 5, 60%; Mid-range none; …".
    private func spokenLabel(_ row: StatsBoxScoreZoneRow) -> String {
        let cells = StatsBoxScoreZoneRow.zones.map { "\($0.boxScoreColumnLabel) \(row.spokenText($0))" }
        return "\(row.name): " + cells.joined(separator: "; ")
    }
}
