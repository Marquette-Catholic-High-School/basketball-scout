import SwiftUI

/// The scouting report tab (03 §5, §7.8; 09 C1–C3, C10, R30, R31): write a report with an optional coach
/// focus, follow the report job, and read the reports natively (version picker, copy as text, share,
/// Markdown download, print).
///
/// A section of the game page: it reads the page's `GameContext` from the environment and has no scroll
/// view of its own (put it in the page's). The page's context loads the reports and follows the report
/// job (every 3 s while the page is visible); the tab's own state lives in `ReportPageModels`, so it
/// survives tab switches.
struct ReportView: View {
    @Environment(GameContext.self) private var context

    init() {}

    var body: some View {
        ReportTabContent(model: ReportPageModels.report(for: context), context: context)
    }
}

/// The report tab's card: header actions, composer, report area, version picker and the report.
private struct ReportTabContent: View {
    let model: ReportViewModel
    let context: GameContext

    var body: some View {
        let reports = model.reports(in: context)
        let selected = model.selectedReport(in: context)
        // The report's title names the team it is about ("Scouting report: <team>").
        let gameTitle = context.reportTeamName(selected?.reportSide ?? model.side)
        Card(title: ReportTexts.tabTitle) {
            ReportComposer(model: model, context: context)
            if let file = model.files.readyFile {
                ReportReadyFilePanel(file: file, handoff: model.files)
            }
            Divider()
            if ReportRules.showsVersionPicker(reportCount: reports.count) {
                versionPicker(reports, selected: selected)
            }
            if let selected {
                ReportDocumentView(record: selected, gameTitle: gameTitle)
                    .id(selected.id)
            } else if !context.hasLoaded {
                HStack(spacing: Theme.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: ReportTexts.loadingReports)
                        .font(Theme.Typography.hint)
                        .foregroundStyle(Theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(verbatim: ReportTexts.noReportYet(team: context.reportTeamName(model.side)))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            if let selected {
                ReportShareActions(record: selected, gameTitle: gameTitle, model: model, context: context)
            }
        }
        .reportFileExporter(model.files) { outcome in
            switch outcome {
            case .saved(let filename):
                context.toasts?.show("Saved \(filename)", tone: .success)
            case .failed(let error):
                model.show(error)
            case .cancelled:
                break
            }
        }
        .onAppear { model.files.appeared() }
        .onDisappear { model.files.disappeared() }
        .onChange(of: context.finishedReportJob?.id, initial: true) {
            model.sync(with: context)
        }
    }

    /// "Version": one option per report, newest first; disabled with fewer than two (03 §7.8).
    private func versionPicker(_ reports: [ReportRecord], selected: ReportRecord?) -> some View {
        let selection = Binding<String>(
            get: { selected?.id ?? reports.first?.id ?? "" },
            set: { model.select($0, in: context) })
        return ReportLabeledControl(label: ReportTexts.versionLabel) {
            Picker(ReportTexts.versionLabel, selection: selection) {
                ForEach(reports) { record in
                    Text(verbatim: ReportRules.versionTitle(record, team: context.reportTeamName(record.reportSide)))
                        .tag(record.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!ReportRules.versionPickerEnabled(reportCount: reports.count))
        }
    }
}

// MARK: - Previews

#Preview("Report tab – reports, regular") {
    ScrollView {
        ReportView()
            .padding()
    }
    .frame(width: 960, height: 1100)
    .environment(GameContext.preview(
        game: ReportPreviewData.game, reports: [ReportPreviewData.report, ReportPreviewData.olderReport],
        health: ReportPreviewData.health))
}

#Preview("Report tab – writing, compact, dark") {
    ScrollView {
        ReportView()
            .padding()
    }
    .frame(width: 390, height: 900)
    .preferredColorScheme(.dark)
    .environment(GameContext.preview(
        game: ReportPreviewData.game, jobs: [ReportPreviewData.writingJob], reports: [ReportPreviewData.report],
        health: ReportPreviewData.health))
}

#Preview("Report tab – empty, Claude not configured, large type") {
    ScrollView {
        ReportView()
            .padding()
    }
    .frame(width: 430, height: 900)
    .dynamicTypeSize(.accessibility1)
    .environment(GameContext.preview(
        game: ReportPreviewData.game, jobs: [ReportPreviewData.queuedJob],
        health: HealthStatus(version: "0.1.0", processor: "mock", queueBackend: "sqlite", claudeConfigured: false)))
}

extension GameContext {
    /// The report the Report tab shows, while that tab is the selected one (File > Print… prints it).
    var reportOnScreen: ReportRecord? {
        guard analysis != nil, selectedTab == .report else { return nil }
        return ReportPageModels.report(for: self).selectedReport(in: self)
    }

    /// File > Print… (⌘P): prints the report the Report tab shows.
    func printReportOnScreen() {
        guard let record = reportOnScreen else { return }
        ReportPageModels.report(for: self).print(record, gameTitle: reportTeamName(record.reportSide))
    }

    /// The name of the team a report is about, as the game page shows it.
    func reportTeamName(_ side: TeamSide) -> String {
        game?.teamName(side, analysis: analysis) ?? side.shortTitle
    }
}
