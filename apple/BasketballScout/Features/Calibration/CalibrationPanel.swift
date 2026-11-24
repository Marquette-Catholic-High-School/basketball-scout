import SwiftUI

/// The calibration panel (game.html:96-122): the hint, the landmark to place with the court diagram, the
/// count line, tips and warnings, Undo / Clear points, Remove saved calibration, the result, and the list of
/// placed points. "Save calibration" is the sheet's toolbar button (always in reach on iPhone).
struct CalibrationPanel: View {
    let model: CalibrationModel

    /// The result area's scroll target.
    static let resultID = "calibration-result"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            if let notice = model.filmNotice {
                NoticeView(tone: .info, message: notice)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(verbatim: CalibrationText.fixedCamerasOnly)
                    .font(Theme.Typography.subsectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: CalibrationText.hint)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CalibrationLandmarkPicker(model: model)
            if let landmarks = model.landmarks, let draft = model.draft {
                CalibrationCourtDiagram(
                    court: landmarks.court,
                    landmarks: draft.landmarks,
                    placed: Set(draft.points.map(\.landmark)),
                    selected: draft.selectedLandmark,
                    selectedLabel: model.selectedLabel,
                    onSelect: { model.select($0) },
                    onAdjust: { model.selectAdjacent(forward: $0) })
            }
            status
            editButtons
            if model.hasSavedCalibration {
                BusyButton(
                    CalibrationText.removeSaved, busyTitle: CalibrationText.removing, isBusy: model.isRemoving, role: .destructive
                ) {
                    model.requestRemoveSaved()
                }
                .buttonStyle(.bordered)
                .touchFriendlyControlSize()
                .disabled(model.isSaving)
            }
            CalibrationResultSection(model: model)
                .id(Self.resultID)
            CalibrationPointList(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { keyShortcuts }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(verbatim: model.countText)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .announcesChanges(of: model.countText)
            if model.showsUnsavedNote {
                Text(verbatim: CalibrationText.unsavedChanges)
                    .font(Theme.Typography.hint)
                    .foregroundStyle(Theme.secondaryText)
            }
            if let tip = model.tip {
                Label {
                    Text(verbatim: tip)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb")
                        .accessibilityHidden(true)
                }
                .font(Theme.Typography.hint)
                .foregroundStyle(Theme.secondaryText)
            }
            ForEach(model.warnings) { warning in
                NoticeView(tone: .warning, title: warning.title, message: warning.message)
            }
        }
    }

    private var editButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.small) { editButtonItems }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) { editButtonItems }
        }
        .buttonStyle(.bordered)
        .touchFriendlyControlSize()
    }

    @ViewBuilder
    private var editButtonItems: some View {
        Button(CalibrationText.undo) { model.undo() }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!model.canUndo)
        Button(CalibrationText.clearPoints) { model.clear() }
            .disabled(!model.canClear)
    }

    /// The Delete key removes the selected landmark's point.
    private var keyShortcuts: some View {
        Button(CalibrationText.removeSelectedPoint) { model.removeSelectedPoint() }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(model.selectedLandmark.flatMap { model.draft?.point(for: $0) } == nil)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

#Preview("Panel") {
    let model = CalibrationPreviewData.model()
    ScrollView {
        CalibrationPanel(model: model)
            .padding()
    }
    .frame(width: 380, height: 900)
}
