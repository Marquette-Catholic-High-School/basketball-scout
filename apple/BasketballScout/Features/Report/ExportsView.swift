import SwiftUI

/// The exports tab (03 §6, §7.9; 09 R45): the FastScout paste block (copied as one pasteboard item with
/// the tab-separated text and the HTML table FastScout reads), its "Check before pasting" notes and team
/// numbers, the FastScout Web custom-table CSV, the timeline CSV, the analysis JSON and the newest report's
/// Markdown, each downloaded with the signed-in client and handed over as a file (save panel / Files,
/// share, drag-out).
///
/// A section of the game page: it reads the page's `GameContext` from the environment and has no scroll
/// view of its own. It loads when shown and again after each page refresh while shown (only while the app
/// is active); the team, table and loaded block live in `ReportPageModels`, so they survive tab switches.
struct ExportsView: View {
    @Environment(GameContext.self) private var context

    init() {}

    var body: some View {
        ReportExportsContent(model: ReportPageModels.exports(for: context), context: context)
    }
}

/// The exports card.
private struct ReportExportsContent: View {
    @Bindable var model: ReportExportsModel
    let context: GameContext

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The game has an analysis on the server (every export needs it; 03 §2.4).
    private var hasAnalysis: Bool { context.analysis != nil || context.game?.hasAnalysis == true }

    var body: some View {
        Card(title: ReportExportsTexts.title) {
            if hasAnalysis {
                if let problem = model.problem {
                    ErrorBox(error: problem.error, retry: problem.retry == nil ? nil : { Task { await model.retry(in: context) } })
                }
                if let file = model.files.readyFile {
                    ReportReadyFilePanel(file: file, handoff: model.files)
                }
                columns
            } else {
                EmptyStateView(
                    title: ReportExportsTexts.noAnalysisTitle, message: ReportExportsTexts.noAnalysisMessage,
                    systemImage: "square.and.arrow.up")
            }
        }
        .taskWhileActive(id: model.loadKey(in: context)) { [model, context] in
            guard context.analysis != nil || context.game?.hasAnalysis == true else { return }
            await model.load(in: context)
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
    }

    /// Two columns where there is room (the web's grid), one column on iPhone and at large text sizes.
    @ViewBuilder
    private var columns: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                ReportFastScoutClassicSection(model: model, context: context)
                ReportCustomTableSection(model: model, context: context)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Spacing.xLarge) {
                    ReportFastScoutClassicSection(model: model, context: context)
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: .infinity, alignment: .topLeading)
                    ReportCustomTableSection(model: model, context: context)
                        .frame(minWidth: 260, idealWidth: 290, maxWidth: .infinity, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                    ReportFastScoutClassicSection(model: model, context: context)
                    ReportCustomTableSection(model: model, context: context)
                }
            }
        }
    }
}

/// "FastScout Stats Database (Classic)": team picker, copy, download, preview, hint, notes (03 §7.9 left).
private struct ReportFastScoutClassicSection: View {
    @Bindable var model: ReportExportsModel
    let context: GameContext

    private var teamName: String { context.teamName(model.side) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SectionTitle(ReportExportsTexts.classicTitle, level: .subsection)
            ReportExportsTeamPicker(model: model, context: context)
            ReportFlowLayout { actions }
            if let notice = model.copyNotice {
                NoticeView(tone: ScoutTone(notice.tone), title: notice.title, message: notice.message, announce: true)
            }
            preview
            Text(verbatim: ReportExportsTexts.classicHint(team: teamName))
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !model.warnings.isEmpty {
                NoticeView(tone: .warning, title: ReportExportsTexts.checkBeforePasting, bullets: model.warnings)
            }
            if !model.teamNumbers.isEmpty {
                teamNumbers
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        BusyButton(
            ReportExportsTexts.copyPasteBlock, busyTitle: ReportExportsTexts.copying, isBusy: model.isCopying,
            isProminent: true
        ) {
            Task { await model.copyPasteBlock(in: context) }
        }
        .touchFriendlyControlSize()
        .help(Text(verbatim: "Copies the paste block for FastScout as text and as a table"))
        ReportDownloadButton(
            kind: .fastScoutText, title: ReportExportsTexts.downloadText, help: "The paste block as a text file",
            model: model, context: context)
    }

    /// The read-only monospaced preview: "Loading…" while fetching, blank after an error (exports.js:116-129).
    private var preview: some View {
        ScrollView(.horizontal) {
            Text(verbatim: model.previewText.isEmpty ? " " : model.previewText)
                .font(Theme.Typography.monospaced)
                .foregroundStyle(model.currentBlock == nil ? Theme.secondaryText : Color.primary)
                .fixedSize()
                .padding(Theme.Spacing.small)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if model.isRefreshingBlock {
                ProgressView()
                    .controlSize(.small)
                    .padding(Theme.Spacing.small)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ReportExportsTexts.previewLabel))
        .accessibilityValue(Text(verbatim: spokenPreview))
        .contextMenu {
            Button {
                Task { await model.copyPasteBlock(in: context) }
            } label: {
                Label(ReportExportsTexts.copyPasteBlock, systemImage: "doc.on.doc")
            }
            .disabled(model.isCopying)
        }
    }

    /// The preview for VoiceOver: one sentence per row, cells separated by commas.
    private var spokenPreview: String {
        guard let block = model.currentBlock else { return model.isLoading ? ReportExportsTexts.loading : "" }
        return ReportTSV.rows(block.text)
            .map { ReportTSV.cells($0).filter { !$0.isEmpty }.joined(separator: ", ") }
            .joined(separator: ". ")
    }

    private var teamNumbers: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    SectionTitle(ReportExportsTexts.teamNumbersTitle, level: .subsection)
                    copyTeamNumbersButton
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    SectionTitle(ReportExportsTexts.teamNumbersTitle, level: .subsection)
                    copyTeamNumbersButton
                }
            }
            Text(verbatim: model.teamNumbers)
                .font(Theme.Typography.monospaced)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .accessibilityLabel(Text(verbatim: ReportExportsTexts.teamNumbersTitle))
                .accessibilityValue(Text(verbatim: model.teamNumbers))
            if let notice = model.teamNumbersNotice {
                NoticeView(tone: ScoutTone(notice.tone), title: notice.title, message: notice.message, announce: true)
            }
        }
    }

    private var copyTeamNumbersButton: some View {
        Button {
            model.copyTeamNumbers()
        } label: {
            Text(verbatim: ReportExportsTexts.copyTeamNumbers)
        }
        .buttonStyle(.bordered)
        .touchFriendlyControlSize()
        .fixedSize()
    }
}

/// "FastScout Web custom table (CSV)" and "Other downloads" (03 §7.9 right).
private struct ReportCustomTableSection: View {
    @Bindable var model: ReportExportsModel
    let context: GameContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SectionTitle(ReportExportsTexts.customTableTitle, level: .subsection)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Spacing.medium) {
                    tablePicker
                    csvButton
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    tablePicker
                    csvButton
                }
            }
            hint(ReportExportsTexts.customTableHint)

            SectionTitle(ReportExportsTexts.otherDownloadsTitle, level: .subsection)
                .padding(.top, Theme.Spacing.small)
            ReportFlowLayout { otherDownloads }
            hint(ReportExportsTexts.otherDownloadsHint)
            if !context.reports.isEmpty {
                hint(ReportExportsTexts.reportMarkdownHint)
            }
        }
    }

    private var tablePicker: some View {
        ReportLabeledControl(label: ReportExportsTexts.tableLabel) {
            Picker(ReportExportsTexts.tableLabel, selection: $model.tableName) {
                ForEach(model.tableOptions, id: \.name) { option in
                    Text(verbatim: option.title).tag(option.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var csvButton: some View {
        ReportDownloadButton(
            kind: .fastScoutCSV, title: ReportExportsTexts.downloadCSV,
            help: "The chosen table for the chosen team, as a CSV file", model: model, context: context)
    }

    @ViewBuilder
    private var otherDownloads: some View {
        ReportDownloadButton(
            kind: .timelineCSV, title: ReportExportsTexts.timelineCSV,
            help: "Every event of the game with its time, team and player", model: model, context: context)
        ReportDownloadButton(
            kind: .analysisJSON, title: ReportExportsTexts.analysisJSON,
            help: "The complete raw analysis", model: model, context: context)
        if !context.reports.isEmpty {
            ReportDownloadButton(
                kind: .reportMarkdown, title: ReportExportsTexts.reportMarkdown,
                help: "The newest scouting report as a Markdown file", model: model, context: context)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Theme.Typography.hint)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Team": the scouted team or its opponent, labelled with their names (03 §7.9).
private struct ReportExportsTeamPicker: View {
    @Bindable var model: ReportExportsModel
    let context: GameContext

    var body: some View {
        ReportLabeledControl(label: ReportExportsTexts.teamLabel) {
            Picker(ReportExportsTexts.teamLabel, selection: $model.side) {
                Text(verbatim: context.teamName(.scouted)).tag(TeamSide.scouted)
                Text(verbatim: context.teamName(.other)).tag(TeamSide.other)
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .onChange(of: model.side) {
            model.teamChanged()
        }
    }
}

/// A download button: "Downloading…" while its file comes, disabled while another one does.
private struct ReportDownloadButton: View {
    let kind: ReportDownloadKind
    let title: String
    let help: String
    let model: ReportExportsModel
    let context: GameContext

    var body: some View {
        BusyButton(title, busyTitle: ReportExportsTexts.downloading, isBusy: model.files.downloading == kind) {
            Task { await model.download(kind, in: context) }
        }
        .buttonStyle(.bordered)
        .touchFriendlyControlSize()
        .disabled(model.files.downloading != nil)
        .help(Text(verbatim: help))
    }
}

// MARK: - Previews

#Preview("Exports – regular") {
    let context = GameContext.preview(
        game: ReportPreviewData.game, reports: [ReportPreviewData.report], health: ReportPreviewData.health)
    ReportPageModels.exports(for: context).fillForPreview()
    return ScrollView {
        ExportsView()
            .padding()
    }
    .frame(width: 980, height: 900)
    .environment(context)
}

#Preview("Exports – compact, dark, large type") {
    let context = GameContext.preview(game: ReportPreviewData.game, health: ReportPreviewData.health)
    ReportPageModels.exports(for: context).fillForPreview()
    return ScrollView {
        ExportsView()
            .padding()
    }
    .frame(width: 390, height: 1000)
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.xxxLarge)
    .environment(context)
}
