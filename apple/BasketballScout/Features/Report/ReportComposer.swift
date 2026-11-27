import SwiftUI

/// Writing a report (03 §7.8 "Controls"): the Claude warning, "Report on", the coach focus field, "Generate report" /
/// "Regenerate report", the status line while the report job runs (with Cancel, 09 R31) and the report
/// area's one message box.
struct ReportComposer: View {
    let model: ReportViewModel
    let context: GameContext

    @State private var confirmation: ConfirmationRequest?

    /// Show the character count from this many characters on.
    static let counterThreshold = 1500

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if context.health?.claudeConfigured == false {
                let warning = ReportTexts.claudeNotConfigured
                NoticeView(tone: ScoutTone(warning.tone), title: warning.title, message: warning.message, hint: warning.hint)
            }
            sidePicker
            focusField
            generateRow
            if let job = model.followedJob(in: context) {
                statusRow(job)
                if job.status == .queued, let notice = context.health?.workerNotice {
                    NoticeView(tone: ScoutTone(notice.tone), title: notice.title, hint: notice.message)
                }
            }
            if let notice = model.notice(in: context) {
                ReportNoticeView(notice: notice, model: model, context: context)
            }
        }
        .confirmAction($confirmation)
    }

    // MARK: Report on

    private var sidePicker: some View {
        let side = Binding(get: { model.side }, set: { model.setSide($0) })
        return VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            ReportLabeledControl(label: ReportTexts.sideLabel) {
                Picker(ReportTexts.sideLabel, selection: side) {
                    ForEach(TeamSide.knownCases, id: \.self) { team in
                        Text(verbatim: context.reportTeamName(team)).tag(team)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Text(verbatim: ReportTexts.sideHint)
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Coach focus

    private var focusField: some View {
        let focus = Binding(get: { model.focusText }, set: { model.setFocus($0) })
        let length = ReportRules.focusLength(model.focusText)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(verbatim: ReportTexts.focusLabel)
                .font(.subheadline.weight(.medium))
                .accessibilityHidden(true)
            TextField(
                ReportTexts.focusLabel, text: focus,
                prompt: Text(verbatim: ReportTexts.focusPlaceholder), axis: .vertical
            )
            .lineLimit(3...8)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(Text(verbatim: ReportTexts.focusLabel))
            if length >= Self.counterThreshold {
                Text(verbatim: "\(length.formatted()) of \(ReportRequest.maximumFocusLength.formatted()) characters")
                    .font(.caption)
                    .foregroundStyle(length >= ReportRequest.maximumFocusLength ? ScoutTone.warning.foreground : Theme.secondaryText)
                    .monospacedDigit()
            }
        }
    }

    // MARK: Generate and status

    private var generateRow: some View {
        let title = ReportRules.generateTitle(hasReports: model.hasReport(in: context))
        return BusyButton(title, busyTitle: title, isBusy: model.isStarting, isProminent: true) {
            Task { await model.generate(in: context) }
        }
        .disabled(!model.canGenerate(in: context))
        .keyboardShortcut(.return, modifiers: .command)
        .touchFriendlyControlSize()
        .help(Text(verbatim: "\(title) (\u{2318}\u{21A9})"))
    }

    private func statusRow(_ job: Job) -> some View {
        let status = ReportRules.statusLine(for: job)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Spacing.small) {
                statusText(status)
                Spacer(minLength: Theme.Spacing.small)
                cancelButton(job)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                statusText(status)
                cancelButton(job)
            }
        }
        .announcesChanges(of: status)
    }

    private func statusText(_ status: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(verbatim: status)
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func cancelButton(_ job: Job) -> some View {
        BusyButton(job.cancelButtonTitle, busyTitle: "Cancelling\u{2026}", isBusy: model.isCancelling, role: .destructive) {
            confirmCancel()
        }
        .buttonStyle(.bordered)
        .disabled(job.cancelRequested)
        .touchFriendlyControlSize()
    }

    /// 09 R31: the report branch of the web's cancel question; confirming still sends the cancel when it
    /// is too late (the job then finishes and the report is kept).
    private func confirmCancel() {
        guard let job = context.activeReportJob else { return }
        let question = job.cancelQuestion
        confirmation = ConfirmationRequest(
            title: question.title, message: question.message,
            confirmTitle: job.isTooLateToCancel ? "Cancel anyway" : ReportTexts.stopReportConfirm,
            isDestructive: !job.isTooLateToCancel,
            cancelTitle: ReportTexts.keepWriting
        ) {
            Task { await model.cancel(in: context) }
        }
    }
}

/// The report area's one box (report.js `report-error`; 07 §5.1: boxes replace each other).
struct ReportNoticeView: View {
    let notice: ReportNotice
    let model: ReportViewModel
    let context: GameContext

    var body: some View {
        switch notice {
        case .actionFailed(let error):
            ErrorBox(error: error)
        case .trackingFailed(let error):
            ErrorBox(error: error, retryTitle: "Check again") { context.checkReportJobAgain() }
        case .reportsFailed(let error):
            ErrorBox(error: error) { Task { await context.refresh() } }
        case .jobFailed(let error):
            // report.js:171-176: "Try again" (a new report) only when the error is retryable.
            ErrorBox(error: error) { Task { await model.generate(in: context) } }
        case .jobCancelled:
            NoticeView(tone: .info, message: ReportTexts.cancelledMessage, announce: true)
        case .jobFinishedWithWarnings(let title, let warnings):
            NoticeView(tone: .warning, title: title, bullets: warnings, announce: true)
        }
    }
}

#Preview("Report area messages") {
    let context = GameContext.preview(game: ReportPreviewData.game, health: ReportPreviewData.health)
    let model = ReportViewModel()
    ScrollView {
        VStack(spacing: Theme.Spacing.medium) {
            ReportNoticeView(
                notice: .jobFailed(ErrorInfo(
                    code: ErrorCode.reportRateLimited, title: "Claude rate limit reached",
                    message: "The Anthropic API is rate limiting this key.",
                    hint: "Wait a minute and click 'Generate report' again.", retryable: true)),
                model: model, context: context)
            ReportNoticeView(
                notice: .actionFailed(ErrorInfo(
                    code: ErrorCode.conflict, title: "Conflict", message: "This game's film is being analysed right now.",
                    hint: "Wait for it to finish, or cancel it first.", retryable: false)),
                model: model, context: context)
            ReportNoticeView(notice: .jobCancelled, model: model, context: context)
            ReportNoticeView(
                notice: .jobFinishedWithWarnings(
                    title: "Scouting report finished with warnings",
                    warnings: ["Cancelled after Claude had started writing the report: the report was kept."]),
                model: model, context: context)
        }
        .padding()
    }
    .frame(width: 520, height: 700)
}
