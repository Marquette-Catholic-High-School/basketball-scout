import SwiftUI

/// The success notice of an import (roster.js `showImportResult`): "Imported 4 players from roster.csv", what
/// changed (added, updated, removed), the columns used, the rows skipped and the importer's "Please check:"
/// warnings (shown verbatim).
struct RosterImportResultView: View {
    let summary: RosterImportSummary
    var announce = true

    var body: some View {
        if summary.hasDetails {
            NoticeView(tone: .success, title: summary.title, message: summary.changes, announce: announce) {
                details
            }
        } else {
            NoticeView(tone: .success, title: summary.title, message: summary.changes, announce: announce)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            if let columns = summary.columns {
                Text(verbatim: columns)
                    .foregroundStyle(Theme.secondaryText)
            }
            if let skippedTitle = summary.skippedTitle {
                Text(verbatim: skippedTitle)
                    .padding(.top, Theme.Spacing.xxSmall)
                bullets(summary.skipped)
            }
            if !summary.warnings.isEmpty {
                Text(verbatim: RosterText.pleaseCheck)
                    .padding(.top, Theme.Spacing.xxSmall)
                bullets(summary.warnings)
            }
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func bullets(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Text(verbatim: "\u{2022}").accessibilityHidden(true)
                    Text(verbatim: line)
                }
            }
        }
    }
}

#Preview("Roster import result") {
    let summary = RosterImportSummary(
        title: RosterText.imported(4, from: "roster.csv"),
        changes: RosterImportChanges(added: 2, updated: 1, removed: 1).text,
        columns: RosterText.columnsUsed([(label: "Jersey", header: "No."), (label: "Name", header: "Player")]),
        skippedTitle: RosterText.skippedRows(1),
        skipped: ["Row 5: invalid jersey number 'abc'"],
        warnings: ["Row 5: 'abc' is not a jersey number (0-99), so Test Player 13 was skipped.", "Row 6: #14 has no name."])
    ScrollView {
        RosterImportResultView(summary: summary, announce: false)
            .padding()
    }
}
