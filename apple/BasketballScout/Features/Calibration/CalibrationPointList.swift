import SwiftUI

/// The placed points (calibrate.js:200-202): "1. Left end: baseline, near corner (40, 330)" with Remove. A
/// row selects its landmark, so the next click moves that point.
struct CalibrationPointList: View {
    let model: CalibrationModel

    var body: some View {
        if let draft = model.draft, !draft.points.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                SectionTitle(CalibrationText.pointsTitle, level: .subsection)
                ForEach(Array(draft.points.enumerated()), id: \.element.landmark) { index, point in
                    row(point, number: index + 1, label: draft.label(for: point.landmark), isSelected: point.landmark == draft.selectedLandmark)
                }
            }
        }
    }

    private func row(_ point: CalibrationPoint, number: Int, label: String, isSelected: Bool) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Button {
                model.select(point.landmark)
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: CalibrationText.pointTitle(number, label))
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: CalibrationText.pixelText(point.px))
                        .font(Theme.Typography.monospaced)
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button(CalibrationText.remove) { model.remove(point.landmark) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(Text(verbatim: CalibrationText.removePoint(number)))
        }
        .padding(.vertical, Theme.Spacing.xSmall)
        .padding(.horizontal, Theme.Spacing.small)
        .background(
            isSelected ? Color.brand.opacity(0.14) : Theme.insetBackground,
            in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .contextMenu {
            Button(CalibrationText.removePoint(number), role: .destructive) { model.remove(point.landmark) }
        }
    }
}
