import SwiftUI

/// A small pill on a colour (07 §10.3): team chips and possession pills (background = team colour,
/// text = readable ink, border = 70 % colour + 30 % text colour), jersey chips, neutral tags.
///
/// - `Chip(text:team:)`: a team colour with its readable ink (`HexColor.ink`, at least 4.5:1) and the
///   web's mixed border (`Theme.teamBorder`).
/// - `Chip(text:color:)`: any colour; the ink is worked out the same way unless `textColor` is given.
/// - `Chip(text:)`: a neutral tag.
struct Chip: View {
    let text: String
    let color: Color?
    let textColor: Color?
    let borderColor: Color?
    let systemImage: String?

    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var horizontalPadding: CGFloat = 7
    @ScaledMetric(relativeTo: .caption) private var verticalPadding: CGFloat = 1

    init(text: String, color: Color? = nil, textColor: Color? = nil, systemImage: String? = nil) {
        self.text = text
        self.color = color
        self.textColor = textColor
        self.borderColor = nil
        self.systemImage = systemImage
    }

    /// A chip in a team colour.
    init(text: String, team: HexColor, systemImage: String? = nil) {
        self.text = text
        self.color = team.color
        self.textColor = team.ink.color
        self.borderColor = Theme.teamBorder(team)
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(Theme.Typography.badge)
        .foregroundStyle(resolvedTextColor)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(resolvedBorderColor, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var fill: Color { color ?? ScoutTone.neutral.background }

    private var resolvedTextColor: Color {
        if let textColor { return textColor }
        guard let color, let rgb = HexColor(color, in: environment) else { return Color.primary }
        return rgb.ink.color
    }

    private var resolvedBorderColor: Color {
        if let borderColor { return borderColor }
        guard let color else { return Theme.separator }
        let text = ScoutPalette.text.resolved(for: colorScheme).color
        return color.mix(with: text, by: 0.3)
    }
}

#Preview("Chips") {
    let palette = TeamPalette(scoutedHint: "dark")
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        HStack {
            Chip(text: "Riverside", team: palette.scouted)
            Text(verbatim: "vs")
            Chip(text: "Eastwood", team: palette.other)
        }
        HStack {
            Chip(text: "\u{25B8} RA 12", team: TeamPalette.defaultScouted)
            Chip(text: "\u{25B8} EAS 13", team: HexColor(0xEEEEEC))
            Chip(text: "\u{2013}")
        }
        HStack {
            Chip(text: "Test Team #14", color: .orange)
            Chip(text: "Navy", team: HexColor.resolve("navy") ?? TeamPalette.defaultScouted)
            Chip(text: "Jan 17, 2026", systemImage: "calendar")
        }
    }
    .padding()
}

#Preview("Chips – dark, large type") {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Chip(text: "Riverside", team: TeamPalette.defaultScouted)
        Chip(text: "Eastwood", team: TeamPalette.defaultOther)
        Chip(text: "Varsity")
    }
    .padding()
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility2)
}
