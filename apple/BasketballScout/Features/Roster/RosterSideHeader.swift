import SwiftUI

/// A roster's heading (roster.js:98-101): the team's colour swatch, "Scouted team" / "Their opponent in this
/// film", and "Unsaved changes" once edited.
struct RosterSideHeader: View {
    let side: TeamSide
    let color: HexColor
    let isDirty: Bool

    @ScaledMetric(relativeTo: .title3) private var swatchSize: CGFloat = 12

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Circle()
                .fill(color.color)
                .overlay(Circle().strokeBorder(Theme.teamBorder(color), lineWidth: 1))
                .frame(width: swatchSize, height: swatchSize)
                .accessibilityHidden(true)
            Text(verbatim: side.rosterTitle)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Color.primary)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.small)
            if isDirty {
                Text(verbatim: RosterText.unsavedChanges)
                    .font(.subheadline)
                    .foregroundStyle(ScoutTone.warning.foreground)
                    .textCase(nil)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Roster headings") {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        RosterSideHeader(side: .scouted, color: TeamPalette.darkPreset, isDirty: false)
        RosterSideHeader(side: .other, color: TeamPalette.defaultOther, isDirty: true)
    }
    .padding()
}
