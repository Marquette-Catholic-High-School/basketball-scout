import SwiftUI

/// "Landmark to click" (game.html:105): the landmarks grouped by end of the court in the documented order
/// (calibrate.js:95-103), with the web's names; placed ones show their point's number.
struct CalibrationLandmarkPicker: View {
    @Bindable var model: CalibrationModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(verbatim: CalibrationText.landmarkPicker)
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
            Picker(selection: $model.selectedLandmark) {
                ForEach(model.landmarkSections) { section in
                    Section {
                        ForEach(section.landmarks) { landmark in
                            Text(verbatim: model.optionTitle(for: landmark))
                                .tag(Optional(landmark.name))
                        }
                    } header: {
                        Text(verbatim: section.group.title)
                    }
                }
            } label: {
                Text(verbatim: CalibrationText.landmarkPicker)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel(Text(verbatim: CalibrationText.landmarkPicker))
            if let note = model.selectedSameSpotNote {
                Label {
                    Text(verbatim: note)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: ScoutTone.warning.systemImage)
                        .accessibilityHidden(true)
                }
                .font(Theme.Typography.hint)
                .foregroundStyle(ScoutTone.warning.foreground)
            }
        }
    }
}
