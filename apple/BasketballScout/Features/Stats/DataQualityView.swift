import SwiftUI

/// The data quality tab (06 §12, 03 §7.10; quality.js): how far to trust the numbers. Facts (court mapped,
/// coordinates, jersey match rate, tracks assigned, ball visible, average event confidence, film,
/// pipeline), the saved calibration, "The court was not mapped" with "Calibrate court" (the calibration
/// sheet), the jerseys no roster has with a link that opens the roster on its jersey assignments (the web's
/// `#tracks`, 05 §7.12), and every warning of the analysis in the web's wording, coloured by severity.
/// `FREE_THROWS_NOT_DETECTED` offers "Full re-analysis" when the game has a calibration and film (disabled
/// while an analysis runs, with the reason as its tooltip). Lives in the game page's scrolling column and
/// draws its own card.
struct DataQualityView: View {
    @Environment(GameContext.self) private var context
    @Environment(AppModel.self) private var appModel: AppModel?
    @State private var confirmation: ConfirmationRequest?
    @State private var startError: (any PresentableError)?
    @State private var showsCalibration = false

    init() {}

    var body: some View {
        StatsAnalysisContent(title: "Data quality", systemImage: "checkmark.seal") { analysis in
            content(StatsDataQualityModel(analysis: analysis, game: context.game, teamName: { context.teamName($0) }))
        }
        .confirmAction($confirmation)
        .sheet(isPresented: $showsCalibration) {
            // The calibration sheet brings its own navigation stack, Close (Escape on the Mac) and size.
            CalibrationView().environment(context)
        }
    }

    private func content(_ model: StatsDataQualityModel) -> some View {
        Card(title: "Data quality") {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                facts(model)
                unmatched(model)
                warnings(model)
            }
        }
    }

    // MARK: Facts and calibration

    private func facts(_ model: StatsDataQualityModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(model.facts) { fact in
                    KeyValueRow(label: fact.label, value: fact.value, monospacedDigits: true)
                    if fact.id != model.facts.last?.id { Divider() }
                }
            }
            .padding(Theme.Spacing.medium)
            .background(Theme.insetBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            if let text = model.calibrationText {
                Label {
                    Text(verbatim: text)
                } icon: {
                    Image(systemName: "viewfinder")
                }
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
            }
            if !model.isCourtMapped {
                NoticeView(
                    tone: .info, title: StatsDataQualityModel.notMappedTitle, message: StatsDataQualityModel.notMappedMessage,
                    actions: calibrateActions)
            }
        }
    }

    // MARK: Jerseys not on a roster

    private func unmatched(_ model: StatsDataQualityModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionTitle(StatsDataQualityModel.unmatchedTitle, level: .subsection)
            if model.unmatchedJerseys.isEmpty {
                StatsHint(StatsDataQualityModel.allMatchedText)
            } else {
                StatsFlowLayout(horizontalSpacing: Theme.Spacing.xSmall, verticalSpacing: Theme.Spacing.xSmall) {
                    ForEach(model.unmatchedJerseys) { jersey in
                        if let side = jersey.side {
                            Chip(text: jersey.text, team: context.teamColor(side))
                        } else {
                            Chip(text: jersey.text)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                Button {
                    openJerseyAssignments()
                } label: {
                    Label {
                        Text(verbatim: StatsDataQualityModel.rosterLinkTitle)
                    } icon: {
                        Image(systemName: "person.crop.rectangle.stack")
                    }
                }
                .buttonStyle(.borderless)
                .accessibilityAddTraits(.isLink)
                .accessibilityHint(Text(verbatim: "Opens the roster and the jersey assignments from the film"))
            }
        }
    }

    // MARK: Warnings

    private func warnings(_ model: StatsDataQualityModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionTitle(StatsDataQualityModel.warningsTitle, level: .subsection)
            if model.warnings.isEmpty {
                StatsHint(StatsDataQualityModel.noWarningsText)
            } else {
                ForEach(model.warnings) { item in
                    NoticeView(
                        tone: ScoutTone(item.tone), title: item.warning.message, hint: item.warning.code,
                        actions: item.offersFullReanalysis ? [fullReanalysisAction] : [])
                }
            }
            if let startError {
                ErrorBox(error: startError)
            }
        }
    }

    private var calibrateActions: [NoticeAction] {
        Self.calibrateActions(isPlayable: context.isPlayable) { showsCalibration = true }
    }

    private var fullReanalysisAction: NoticeAction {
        Self.fullReanalysisAction(isBusy: context.isBusy, isStarting: context.isStartingJob) {
            confirmation = StatsFullReanalysis.confirmation {
                Task {
                    startError = nil
                    startError = await StatsFullReanalysis.start(in: context)
                }
            }
        }
    }

    /// "Calibrate court" (quality.js:60-63), only when the film can be played: opens the calibration sheet.
    static func calibrateActions(isPlayable: Bool, perform: @escaping () -> Void) -> [NoticeAction] {
        guard isPlayable else { return [] }
        return [NoticeAction(StatsDataQualityModel.calibrateTitle, help: PlayerText.calibrateHelp, perform: perform)]
    }

    /// quality.js `fullRunAction`: confirm, then start; "Starting…" while it is sent, disabled while an
    /// analysis is queued or running, with the reason as its tooltip ("An analysis is already running").
    static func fullReanalysisAction(isBusy: Bool, isStarting: Bool, perform: @escaping () -> Void) -> NoticeAction {
        NoticeAction(
            StatsDataQualityModel.fullReanalysisTitle, isPrimary: true, busyTitle: "Starting\u{2026}",
            isBusy: isStarting, isDisabled: isBusy, help: StatsDataQualityModel.fullReanalysisHelp(isBusy: isBusy),
            perform: perform)
    }

    private func openJerseyAssignments() {
        Self.openJerseyAssignments(gameID: context.gameID, appModel: appModel)
    }

    /// The roster link (the web's `/games/{id}/roster#tracks`, 05 §7.12): the roster page is pushed and opens on
    /// the jersey assignments from the film.
    static func openJerseyAssignments(gameID: String, appModel: AppModel?) {
        RosterView.showJerseyAssignments(forGame: gameID)
        appModel?.navigate(to: .roster)
    }
}

#if DEBUG
#Preview("Stats – Data quality – warnings") {
    StatsPreviewScreen(analysis: StatsPreviewData.analysis(identifiedPlayers: false, warnings: StatsPreviewData.sampleWarnings)) {
        DataQualityView()
    }
}

#Preview("Stats – Data quality – court not mapped, dark") {
    StatsPreviewScreen(game: StatsPreviewData.game(calibrated: false), analysis: StatsPreviewData.analysis(courtMapped: false)) {
        DataQualityView()
    }
    .preferredColorScheme(.dark)
}

#Preview("Stats – Data quality – analysis running") {
    StatsPreviewScreen(
        game: StatsPreviewData.game(status: .processing),
        analysis: StatsPreviewData.analysis(warnings: StatsPreviewData.sampleWarnings)
    ) {
        DataQualityView()
    }
}
#endif
