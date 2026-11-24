import SwiftUI

/// One scouting report, rendered natively from its JSON as the web does (report.js `renderReport`;
/// 03 §5.3), never from the Markdown: the heading with the game's current title, who wrote it and when,
/// the coach focus, a cut-off warning for legacy records, the headline, the summary paragraphs, then the
/// sections in the web's order (empty ones left out). Every server string is shown verbatim; the text can
/// be selected (and copied) on the Mac and with a long press on iOS.
struct ReportDocumentView: View {
    let record: ReportRecord
    let gameTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            header
            if record.wasCutOff {
                NoticeView(
                    tone: .warning, title: ReportTexts.cutOff.title, message: ReportTexts.cutOff.message,
                    hint: ReportTexts.cutOff.hint)
            }
            if let headline = ServerText.nonEmpty(record.report.headline) {
                Text(verbatim: headline)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !record.report.summaryParagraphs.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    ForEach(Array(record.report.summaryParagraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(verbatim: paragraph)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(record.report.reportSections) { section in
                sectionView(section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(verbatim: ReportTexts.heading(gameTitle: gameTitle))
                .font(Theme.Typography.sectionTitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: ReportTexts.written(date: ScoutFormat.dateTime(record.createdAt), model: record.model))
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
            if let focus = ServerText.nonEmpty(record.coachFocus) {
                Text(verbatim: ReportTexts.coachFocus(focus))
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionView(_ section: ReportSection) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionTitle(section.title, level: .subsection)
            switch section {
            case .keyPlayers:
                ReportKeyPlayersView(players: record.report.keyPlayers)
            case .playTendencies:
                ReportTendenciesView(tendencies: record.report.playTendencies)
            default:
                ReportBulletList(items: record.report.reportItems(section), numbered: section.isNumbered)
                    .foregroundStyle(section.isMuted ? AnyShapeStyle(Theme.secondaryText) : AnyShapeStyle(.primary))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Report – regular") {
    ScrollView {
        ReportDocumentView(record: ReportPreviewData.report, gameTitle: "Test Team A vs Test Team B")
            .padding()
    }
    .frame(width: 900, height: 900)
}

#Preview("Report – compact, dark, large type") {
    ScrollView {
        ReportDocumentView(record: ReportPreviewData.cutOffReport, gameTitle: "Test Team A vs Test Team B")
            .padding()
    }
    .frame(width: 390, height: 900)
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
