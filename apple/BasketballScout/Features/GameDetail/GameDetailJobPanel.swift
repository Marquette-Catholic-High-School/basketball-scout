import SwiftUI

/// The job panel for the latest analysis job (03 §7.3 row 3, §7.5; jobpanel.js):
///
/// - queued / running: "<kind> in progress", the stage line, the progress bar (indeterminate while queued),
///   "NN% overall · <message> · running for …", Cancel (with the question for the job's stage), the "worker
///   not running" notice while queued, and "You can leave this screen or close the app; processing continues on the server.";
/// - succeeded with warnings: "<kind> finished with warnings" and the list;
/// - cancelled: "<kind> was cancelled" with "Start again";
/// - failed: the job's error with "Re-run analysis", "Retry" or no button, technical details for IT;
/// - following the job gave up: the error with "Check again".
///
/// VoiceOver hears stage changes (not the details line that changes with every poll, 07 §5.6) and the final
/// state.
struct GameDetailJobPanel: View {
    @Environment(GameContext.self) private var context
    @Environment(GameDetailModel.self) private var model

    var body: some View {
        if let trackingError = context.jobTrackingError {
            ErrorBox(error: trackingError, actions: [
                NoticeAction(GameDetailText.checkAgain, isPrimary: true) { model.checkJobAgain() },
            ])
        } else {
            switch model.jobPanel {
            case .hidden:
                EmptyView()
            case .active(let active):
                GameDetailActiveJobCard(active: active, workerNotice: context.workerNotice, error: model.visiblePanelError) {
                    model.requestCancel(active.job)
                }
            case .finishedWithWarnings(let title, let warnings):
                NoticeView(tone: .warning, title: title, bullets: warnings, announce: true)
            case .cancelled(let finished):
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    if let notice = finished.notice {
                        NoticeView(
                            tone: ScoutTone(notice.tone), title: notice.title, message: notice.message, hint: notice.hint,
                            announce: true, actions: restartActions(finished))
                    }
                    if let error = model.visiblePanelError {
                        ErrorBox(error: error)
                    }
                }
            case .failed(let finished):
                // A failed retry replaces the job's own error in the panel (jobpanel.js `start`), with the button kept.
                ErrorBox(error: model.visiblePanelError ?? finished.error ?? finished.job.failureInfo, actions: restartActions(finished))
            }
        }
    }

    /// Start again / Retry / Re-run analysis, "Starting…" while it is sent (07 §5.4).
    private func restartActions(_ finished: GameDetailJobPanelState.Finished) -> [NoticeAction] {
        guard let action = finished.action else { return [] }
        let isRestarting = model.restartingJobID == finished.job.id
        return [
            NoticeAction(
                action.title, isPrimary: true, busyTitle: GameDetailText.starting, isBusy: isRestarting,
                isDisabled: model.isWorking && !isRestarting
            ) {
                model.requestRestart(finished.job)
            },
        ]
    }
}

/// The panel of a queued or running job.
private struct GameDetailActiveJobCard: View {
    let active: GameDetailJobPanelState.Active
    /// The "worker not running" notice while the job waits in the queue (07 §6 loop 4).
    let workerNotice: NoticeText?
    /// A cancel that failed.
    let error: (any PresentableError)?
    let onCancel: () -> Void

    private var shownWorkerNotice: NoticeText? { active.isQueued ? workerNotice : nil }

    var body: some View {
        Card(title: active.title) {
            ProgressBlock(
                fraction: active.fraction, title: active.stage, subtitle: active.details,
                accessibilityLabel: GameDetailText.analysisProgress)
            if let notice = shownWorkerNotice {
                // The hint names server commands, so it sits behind "Technical details (for IT staff)" (09 R47).
                NoticeView(tone: ScoutTone(notice.tone), title: notice.title, hint: notice.message)
            }
            if let error {
                ErrorBox(error: error)
            }
            // A live job follows the stream: "End live game" finishes it, Cancel breaks it off.
            Text(verbatim: active.job.kind == .live ? LiveText.jobPanelFooter : GameDetailText.jobPanelFooter)
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            Button(role: .destructive, action: onCancel) {
                Text(verbatim: active.cancelTitle)
            }
            .buttonStyle(.bordered)
            .touchFriendlyControlSize()
            .disabled(!active.canCancel)
        }
        .announcesChanges(of: active.stage)
        // Announced when the problem changes, not with every newer "last seen" time (jobpanel.js:166-168).
        .onChange(of: shownWorkerNotice?.message, initial: true) { _, problem in
            guard problem != nil, let notice = shownWorkerNotice else { return }
            ScoutAnnouncer.announce(ServerText.sentences([ScoutTone(notice.tone).accessibilityName, notice.title]), priority: .high)
        }
    }
}

#Preview("GameDetail – job panel states") {
    let failure = GameDetailPreviewData.failure
    ScrollView {
        VStack(spacing: Theme.Spacing.large) {
            ForEach(Array(GameDetailPreviewData.panelJobs(failure: failure).enumerated()), id: \.offset) { _, job in
                GameDetailPreviewData.panel(for: job)
            }
        }
        .padding()
    }
    .scoutPageBackground()
}
