import SwiftUI

/// The "Key players" table (report.js `keyPlayersTable`; 03 §5.3): `#`, Player, Role, Threat (badge: High
/// red, Medium amber, Low green), Strengths and Weaknesses (bullets), How to defend. A table where there is
/// room (iPad, Mac); one card per player on iPhone and at accessibility text sizes.
struct ReportKeyPlayersView: View {
    let players: [KeyPlayer]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The narrowest width that still shows the table.
    static let tableMinimumWidth: CGFloat = 680
    static let columnShares: [CGFloat] = [0.5, 1.4, 1.3, 0.95, 1.9, 1.9, 2.1]

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            cards
        } else {
            ViewThatFits(in: .horizontal) {
                table
                    .frame(minWidth: Self.tableMinimumWidth, idealWidth: Self.tableMinimumWidth, maxWidth: .infinity, alignment: .leading)
                cards
            }
        }
    }

    // MARK: Table (regular width)

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReportTableHeader(titles: ReportTexts.keyPlayerColumns, fractions: Self.columnShares)
            Divider()
            ForEach(Array(players.enumerated()), id: \.offset) { index, player in
                ReportColumnsLayout(fractions: Self.columnShares) {
                    Text(verbatim: player.reportJerseyNumber).monospacedDigit()
                    Text(verbatim: player.name).fontWeight(.semibold)
                    Text(verbatim: player.role)
                    threatBadge(player.threatLevel)
                    ReportBulletList(items: player.strengths)
                    ReportBulletList(items: player.weaknesses)
                    Text(verbatim: player.howToDefend)
                }
                .font(.subheadline)
                .padding(.vertical, Theme.Spacing.small)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: Self.spokenRow(player)))
                if index < players.count - 1 { Divider() }
            }
        }
    }

    // MARK: Cards (compact width, large text)

    private var cards: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ForEach(Array(players.enumerated()), id: \.offset) { _, player in
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Text(verbatim: [player.reportJerseyLabel, player.name].filter { !$0.isEmpty }.joined(separator: " "))
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        threatBadge(player.threatLevel)
                    }
                    if let role = ServerText.nonEmpty(player.role) {
                        Text(verbatim: role)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if !player.strengths.isEmpty {
                        ReportLabeledBlock(label: ReportTexts.keyPlayerColumns[4]) { ReportBulletList(items: player.strengths) }
                    }
                    if !player.weaknesses.isEmpty {
                        ReportLabeledBlock(label: ReportTexts.keyPlayerColumns[5]) { ReportBulletList(items: player.weaknesses) }
                    }
                    if let defend = ServerText.nonEmpty(player.howToDefend) {
                        ReportLabeledBlock(label: ReportTexts.keyPlayerColumns[6]) {
                            Text(verbatim: defend).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.subheadline)
                .padding(Theme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func threatBadge(_ level: ThreatLevel) -> some View {
        StatusBadge(text: level.label, tone: ScoutTone(level.tone))
            .accessibilityLabel(Text(verbatim: "Threat: \(level.label)"))
    }

    /// What VoiceOver reads for a table row: "#5, Test Player 1, Primary ball handler, Threat: High.
    /// Strengths: …. Weaknesses: …. How to defend: …."
    static func spokenRow(_ player: KeyPlayer) -> String {
        var parts = [ScoutFormat.joined([player.reportJerseyLabel, player.name, player.role]).replacingOccurrences(of: ScoutFormat.separator, with: ", ")]
        parts[0] += ", Threat: \(player.threatLevel.label)"
        let strengths = player.strengths.filter { ServerText.nonEmpty($0) != nil }
        let weaknesses = player.weaknesses.filter { ServerText.nonEmpty($0) != nil }
        if !strengths.isEmpty { parts.append("Strengths: " + strengths.joined(separator: "; ")) }
        if !weaknesses.isEmpty { parts.append("Weaknesses: " + weaknesses.joined(separator: "; ")) }
        if let defend = ServerText.nonEmpty(player.howToDefend) { parts.append("How to defend: " + defend) }
        return ServerText.sentences(parts)
    }
}

/// The "Play tendencies" table (report.js `tendenciesTable`; 03 §5.3): Play type, Frequency, Effectiveness,
/// How to counter. Cards on iPhone and at accessibility text sizes.
struct ReportTendenciesView: View {
    let tendencies: [PlayTendency]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let tableMinimumWidth: CGFloat = 520
    static let columnShares: [CGFloat] = [1.3, 1.2, 1.2, 2.3]

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            cards
        } else {
            ViewThatFits(in: .horizontal) {
                table
                    .frame(minWidth: Self.tableMinimumWidth, idealWidth: Self.tableMinimumWidth, maxWidth: .infinity, alignment: .leading)
                cards
            }
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReportTableHeader(titles: ReportTexts.tendencyColumns, fractions: Self.columnShares)
            Divider()
            ForEach(Array(tendencies.enumerated()), id: \.offset) { index, tendency in
                ReportColumnsLayout(fractions: Self.columnShares) {
                    Text(verbatim: tendency.playType).fontWeight(.semibold)
                    Text(verbatim: tendency.frequency)
                    Text(verbatim: tendency.effectiveness)
                    Text(verbatim: tendency.counter)
                }
                .font(.subheadline)
                .padding(.vertical, Theme.Spacing.small)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: Self.spokenRow(tendency)))
                if index < tendencies.count - 1 { Divider() }
            }
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ForEach(Array(tendencies.enumerated()), id: \.offset) { _, tendency in
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Text(verbatim: tendency.playType).font(.headline)
                    ReportLabeledBlock(label: ReportTexts.tendencyColumns[1]) { Text(verbatim: tendency.frequency) }
                    ReportLabeledBlock(label: ReportTexts.tendencyColumns[2]) { Text(verbatim: tendency.effectiveness) }
                    ReportLabeledBlock(label: ReportTexts.tendencyColumns[3]) {
                        Text(verbatim: tendency.counter).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.subheadline)
                .padding(Theme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// "Transition, Frequency: 37.5% of possessions, Effectiveness: …. How to counter: …."
    static func spokenRow(_ tendency: PlayTendency) -> String {
        ServerText.sentences([
            "\(tendency.playType), Frequency: \(tendency.frequency), Effectiveness: \(tendency.effectiveness)",
            ServerText.nonEmpty(tendency.counter).map { "How to counter: \($0)" },
        ])
    }
}
