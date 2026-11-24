import SwiftUI

/// The result area (calibrate.js:233-290): the fit verdict with "Re-run analysis" / "Analyze film" and, when
/// free throws were missed, "Full re-analysis"; or the notice after removing; or an error.
struct CalibrationResultSection: View {
    let model: CalibrationModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let calibration = model.fitCalibration {
                NoticeView(
                    tone: ScoutTone(calibration.fitQuality.tone),
                    title: CalibrationText.resultTitle(calibration),
                    message: CalibrationText.resultMessage,
                    hint: model.resultHint,
                    announce: model.announcesFit
                ) {
                    jobButtons
                }
                if model.jobsBlocked {
                    Text(verbatim: Game.analysisRunningHelp)
                        .font(Theme.Typography.hint)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            switch model.outcome {
            case .removed(let text)?:
                NoticeView(tone: .info, message: text, announce: true)
            case .saveFailed(let error)?:
                ErrorBox(error: error) { Task { await model.save() } }
            case .removeFailed(let error)?:
                ErrorBox(error: error) { Task { await model.removeSaved() } }
            case nil:
                EmptyView()
            }
            if let error = model.jobError {
                ErrorBox(error: error)
            }
        }
    }

    @ViewBuilder
    private var jobButtons: some View {
        let full = model.offersFullReanalysis
        BusyButton(
            model.rerunTitle, busyTitle: CalibrationText.starting, isBusy: model.startingJob == .rerun, isProminent: !full
        ) {
            Task { await model.startRerun() }
        }
        .disabled(model.jobsBlocked)
        .calibrationHelp(model.rerunHelp)
        if full {
            BusyButton(
                CalibrationText.fullReanalysis, busyTitle: CalibrationText.starting, isBusy: model.startingJob == .full,
                isProminent: true
            ) {
                model.requestFullReanalysis()
            }
            .disabled(model.jobsBlocked)
            .calibrationHelp(model.jobsBlocked ? Game.analysisRunningHelp : model.context.game?.fullReanalysisHelp)
        }
    }
}

private extension View {
    /// `.help` only when there is something to say.
    @ViewBuilder
    func calibrationHelp(_ text: String?) -> some View {
        if let text {
            help(Text(verbatim: text))
        } else {
            self
        }
    }
}
